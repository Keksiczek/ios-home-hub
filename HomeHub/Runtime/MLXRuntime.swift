import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import Hub
import os

// Used to track download→prepare phase transition inside a @Sendable closure.
// Accesses happen sequentially within a single loader.load() call, so the
// @unchecked Sendable is safe: there is no concurrent access to preparingSent.
private final class PhaseSignal: @unchecked Sendable {
    var preparingSent = false
}

/// MLX-backed local runtime for Apple Silicon — the primary backend.
///
/// **Why this is the default:** MLX has no native binary dependency beyond
/// what SPM resolves (`mlx-swift`, `mlx-swift-lm`, `swift-transformers`
/// via its `Transformers` product). It runs out-of-the-box on a fresh checkout, no
/// xcframework drop required, and uses Apple's Metal compute graph
/// directly. The optional `LlamaCppRuntime` is the secondary path; see
/// `RoutingRuntime`.
///
/// **Loading lifecycle** (see `loadWithProgress`):
/// 1. `.downloading(fraction:)` — Hub downloader fetches weights, real
///    `Foundation.Progress` is forwarded to the UI.
/// 2. `.preparing` — download done; weights map into memory and Metal
///    pipeline compiles. No fraction available; the UI shows an
///    indeterminate spinner.
/// 3. Container is cached on the runtime and reused for subsequent
///    `generate()` calls until `unload()` or memory pressure clears it.
///
/// **Generation** uses the canonical `MLXLLM.ChatSession` path when the
/// container is the native `ModelContainer` type, reusing the session for
/// matching conversation prefixes (KV-cache reuse). A stateless
/// `MLXLMCommon.generate(...)` fallback exists for tests / non-native
/// containers.
///
/// **State isolation:** all mutable fields are protected by `sessionLock`
/// (`NSLock`). The class is intentionally NOT an actor — keeping
/// `generate()` non-async on the call site makes the `AsyncThrowingStream`
/// API ergonomic for callers. Each lock acquisition holds for the
/// minimum time needed.
///
/// **Concurrency invariants:**
/// - `isGenerating` is the single authoritative "busy" flag. Set to `true`
///   atomically (under lock) before a generation task starts and reset
///   (under lock) when the task completes, is cancelled, or the runtime
///   is unloaded.
/// - `activeTask` is a cancellation handle only; never used for the busy
///   check.
/// - `container` and `activeSession` are both guarded by `sessionLock`.
final class MLXRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "mlx"

    private let log = Logger(subsystem: "HomeHub", category: "MLXRuntime")
    let telemetry = RuntimeTelemetry()

    private var _loadedModel: LocalModel?
    var loadedModel: LocalModel? {
        get { _loadedModel }
        set { _loadedModel = newValue }
    }

    /// `LocalLLMRuntime` conformance. Returns the conversation whose
    /// `ChatSession` is currently held in the prefix-reuse cache, or
    /// `nil` if nothing is cached. Read under `sessionLock` so the
    /// answer is consistent with `activeSession` itself.
    var activeSessionConversationID: UUID? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return activeSession?.conversationID
    }

    #if DEBUG
    /// Pre-existing debug alias kept for backward-compat with any
    /// internal call site that referenced it. New code should use
    /// `activeSessionConversationID` (now always available).
    var internalActiveSessionConversationID: UUID? { activeSessionConversationID }
    #endif

    private var container: (any MLXModelContainer)?
    private var activeTask: Task<Void, Never>?
    private var activeGenerationID: UUID?
    /// Single authoritative "busy" flag. Protected by sessionLock.
    private var isGenerating: Bool = false
    private let sessionLock = NSLock()

    private struct ActiveSession: @unchecked Sendable {
        /// The model the session was constructed under. The reuse check
        /// also gates on this — same conversationID but different model
        /// ID must invalidate the KV cache, since the cached prefix is
        /// tokenised against a different vocab.
        let modelID: String
        let conversationID: UUID
        let systemPrompt: String
        /// Canonical history snapshot: messages *excluding* the in-flight
        /// user turn. Used as both the seed history for `ChatSession` AND
        /// the comparison key for "is the cached prefix still valid?".
        /// Keeping a single canonical form on both sides removes the risk
        /// of constructing a session from one shape and verifying with
        /// another.
        var messages: [RuntimeMessage]
        let session: ChatSession
    }
    private var activeSession: ActiveSession?

    private let loader: any MLXLoader

    /// Suppresses repeat warnings about unsupported sampler parameters so
    /// they appear only once per model load rather than on every generation.
    private var hasLoggedSamplerWarnings = false

    // MARK: - Telemetry / diagnostics

    /// Rolling mean tokens-per-second per model ID, weighted Welford-style
    /// average. Read by `DeveloperDiagnosticsView` for the throughput
    /// readout. Protected by `sessionLock`.
    private var tpsAverage: [String: (mean: Double, n: Int)] = [:]

    /// Last generation that failed for a user-actionable reason.
    /// Surfaced in Model Info + DeveloperDiagnostics. Cleared on the next
    /// successful generation. Protected by `sessionLock`.
    private var _lastGenerationError: GenerationFailure?

    /// User-facing snapshot of the last generation failure. Read-only
    /// from any thread (uses the same lock as the writer).
    var lastGenerationError: GenerationFailure? {
        sessionLock.withLock { _lastGenerationError }
    }

    /// Snapshot the rolling throughput so diagnostics can render it.
    func averageThroughput(for modelID: String) -> (tps: Double, samples: Int)? {
        sessionLock.withLock {
            guard let entry = tpsAverage[modelID], entry.n > 0 else { return nil }
            return (entry.mean, entry.n)
        }
    }

    init(loader: any MLXLoader = DefaultMLXLoader()) {
        self.loader = loader
        // Configure MLX GPU memory cache limit using the *minimum* of two budgets:
        //   1. DeviceMemoryProvider — how much RAM the sandbox actually has.
        //   2. HardwareCapabilities  — how much we trust this SoC's Metal stack.
        //
        // The two budgets are orthogonal: an 8 GB iPad Pro M2 (memory-generous,
        // no SDPA regression) and a 4 GB iPhone 11 (memory-tight, A13 regression)
        // need very different ceilings. Taking `min` ensures the smaller of the
        // two constraints always wins.
        let memoryBudget   = DeviceMemoryProvider.shared.profile.mlxGPUCacheLimitBytes
        let hardwareBudget = HardwareCapabilities.shared.safeGPUCacheLimitBytes
        let cacheLimitBytes = min(memoryBudget, hardwareBudget)
        MLX.Memory.cacheLimit = Int(cacheLimitBytes)

        if HardwareCapabilities.shared.safeAttentionMode {
            // Safe-mode is purely advisory for MLX-Swift today — the framework
            // does not expose a "disable Flash Attention" toggle. We surface it
            // via DeveloperDiagnostics + log it here so users on flagged SoCs
            // can correlate slow / garbled output with the device.
            log.notice(
                "MLX: safe-attention mode active for SoC \(HardwareCapabilities.shared.soc.label, privacy: .public) — GPU cache clamped to \(Int(cacheLimitBytes / 1024 / 1024), privacy: .public) MB"
            )
        }
    }

    // MARK: - LocalLLMRuntime

    /// Protocol-required load (no progress). Delegates to `loadWithProgress`.
    func load(model: LocalModel) async throws {
        try await loadWithProgress(model: model, progressHandler: nil)
    }

    /// Extended load with phase-reporting callback.
    ///
    /// Two-phase load:
    /// 1. **Download** (cold cache): Fetches weights from Hugging Face Hub.
    ///    Reports real `Foundation.Progress` fractions as `.downloading(fraction:)`.
    ///    When the download fraction reaches 1.0, emits `.preparing` to signal
    ///    the start of Metal pipeline compilation (~10–60 s on iPhone).
    /// 2. **Prepare** (warm cache or after download): Loads weights into memory
    ///    and compiles Metal. For warm-cache loads where no download callbacks
    ///    fire, `.preparing` is emitted immediately so the UI has honest state.
    ///
    /// ## Cancellation
    /// Both phases honour Swift cooperative cancellation via `Task.cancel()`.
    func loadWithProgress(
        model: LocalModel,
        progressHandler: (@Sendable (MLXLoadPhase) -> Void)?
    ) async throws {
        let alreadyGenerating = sessionLock.withLock { isGenerating }
        if alreadyGenerating {
            throw RuntimeError.generationInProgress
        }

        self.log.info("MLX: Preparing to load model '\(model.displayName, privacy: .public)'")

        guard let repoId = model.repoId else {
            throw RuntimeError.incompatibleModel(
                "MLX models must be hosted on Hugging Face. Invalid URL: \(model.downloadURL.absoluteString)"
            )
        }

        // autoreleasepool drains Objective-C temporaries created during synchronous
        // setup (NSString, NSDictionary, intermediate JSON slices for model config
        // and tokenizer metadata). These objects accumulate before the first async
        // suspension point; draining them here minimises the peak Unified Memory
        // footprint at the start of the load sequence.
        let (config, downloader, tokenizerLoader) = autoreleasepool {
            (
                ModelConfiguration(id: repoId),
                HubApiDownloader(),
                SwiftTransformersTokenizerLoader(modelFamily: model.family)
            )
        }

        // Emit .preparing when download fraction hits 1.0 (download done,
        // Metal compilation begins). For warm-cache loads where no progress
        // callbacks fire, we emit .preparing after loader.load() returns.
        let phaseSignal = PhaseSignal()
        let progressAdapter: @Sendable (Progress) -> Void = { progress in
            let fraction = max(0, min(1, progress.fractionCompleted))
            if fraction >= 1.0, !phaseSignal.preparingSent {
                phaseSignal.preparingSent = true
                progressHandler?(.preparing)
            } else if fraction < 1.0 {
                progressHandler?(.downloading(fraction: fraction))
            }
        }

        self.log.debug("MLX: Starting load for '\(repoId, privacy: .public)'")
        let start = Date()

        do {
            self.container = try await loader.load(
                configuration: config,
                downloader: downloader,
                tokenizerLoader: tokenizerLoader,
                progressHandler: progressAdapter
            )

            // Warm cache: no download progress fired → signal prepare phase now.
            // At this point loader.load() has already returned, so the signal
            // fires just before RuntimeManager clears mlxLoadProgress.
            if !phaseSignal.preparingSent {
                progressHandler?(.preparing)
            }

            // A new container invalidates any cached session from the previous load.
            // Reset the sampler-warning flag so the next generation logs once.
            sessionLock.withLock {
                activeSession = nil
                hasLoggedSamplerWarnings = false
            }

            let duration = Int(Date().timeIntervalSince(start) * 1000)
            self.loadedModel = model
            await telemetry.emit(.modelLoaded(handle: ModelHandle(from: model), durationMs: duration))
            self.log.info("MLX: Model '\(model.displayName, privacy: .public)' loaded in \(duration)ms")
        } catch is CancellationError {
            // Defensive cleanup. RuntimeManager.unload() already cleared
            // these before the load began, but the loader can also be
            // cancelled mid-init after a partial container assignment in
            // future MLX revisions — keep the runtime observably empty so
            // a subsequent generate() doesn't see a half-constructed state.
            sessionLock.withLock {
                self.container = nil
                self.activeSession = nil
            }
            self.loadedModel = nil
            self.log.info("MLX: Load cancelled for '\(repoId, privacy: .public)'")
            throw CancellationError()
        } catch {
            sessionLock.withLock {
                self.container = nil
                self.activeSession = nil
            }
            self.loadedModel = nil
            let descriptiveError = error.mlxDescriptiveMessage
            self.log.error("MLX: Failed to load model '\(repoId, privacy: .public)': \(descriptiveError, privacy: .public)")

            throw RuntimeError.initializationFailed("Failed to load MLX model: \(descriptiveError)")
        }
    }

    func unload() async {
        // Snapshot what we're releasing for the structured log line.
        let droppedModelID = loadedModel?.id ?? "(none)"
        let hadSession: Bool = sessionLock.withLock { activeSession != nil }
        let hadContainer: Bool = sessionLock.withLock { container != nil }
        let safeMode = HardwareCapabilities.shared.safeAttentionMode

        sessionLock.withLock {
            activeTask?.cancel()
            activeTask = nil
            activeGenerationID = nil
            isGenerating = false
            // Dropping `activeSession` first releases the `ChatSession`'s
            // strong reference to the container; dropping `container`
            // second lets ARC free the model weights and KV cache buffers
            // in one wave instead of leaving them anchored by the session.
            activeSession = nil
            container = nil
            _lastGenerationError = nil
        }
        loadedModel = nil

        // Structured unload log — surfaced in DeveloperDiagnostics.
        // We don't have a portable "bytes released" API on MLX-Swift, so
        // we log what we actually called (drop session, drop container)
        // and the SoC safe-mode flag for post-hoc correlation.
        self.log.info(
            "MLX runtime unload: modelID=\(droppedModelID, privacy: .public) safeMode=\(safeMode, privacy: .public) droppedSession=\(hadSession, privacy: .public) droppedContainer=\(hadContainer, privacy: .public)"
        )
    }

    func invalidateSession(for conversationID: UUID) async {
        sessionLock.withLock {
            if activeSession?.conversationID == conversationID {
                self.log.info("MLX: Invalidating session for conversation \(conversationID, privacy: .public)")
                activeSession = nil
            }

            if activeGenerationID == conversationID {
                self.log.info("MLX: Cancelling active generation for conversation \(conversationID, privacy: .public) due to invalidation")
                activeTask?.cancel()
                activeTask = nil
                activeGenerationID = nil
                isGenerating = false
            }
        }
    }

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<RuntimeEvent, Error>.makeStream()

        let conversationID = parameters.conversationID ?? UUID()

        self.sessionLock.lock()
        guard !self.isGenerating else {
            self.sessionLock.unlock()
            self.log.warning("MLX: Generation/load already in progress — blocking concurrent request for \(conversationID, privacy: .public)")
            continuation.finish(throwing: RuntimeError.generationInProgress)
            return stream
        }
        self.isGenerating = true
        self.activeGenerationID = conversationID
        self.sessionLock.unlock()

        // [weak self] breaks the retain cycle: self.activeTask → Task → self.
        // The cycle is temporary (resolves when the task finishes), but without
        // weak capture it keeps the runtime alive indefinitely on cancellation.
        let task = Task { [weak self] in
            guard let self else {
                continuation.finish(throwing: RuntimeError.cancelled)
                return
            }
            do {
                guard let container = self.container else {
                    continuation.finish(throwing: RuntimeError.noModelLoaded)
                    self.sessionLock.withLock {
                        // Mirror the success/catch branches: clear the task
                        // handle on every exit so a later `unload()` doesn't
                        // call `.cancel()` on a stale completed Task. There's
                        // a benign race with the outer `self.activeTask = task`
                        // assignment below (which can run after this exit and
                        // re-store a stale ref) — but it's overwritten on the
                        // next generate() and `.cancel()` on a finished Task
                        // is a no-op, so the worst case is one dead reference.
                        self.activeTask = nil
                        self.isGenerating = false
                        self.activeGenerationID = nil
                    }
                    return
                }

                let needsWarning: Bool = self.sessionLock.withLock {
                    if !self.hasLoggedSamplerWarnings {
                        self.hasLoggedSamplerWarnings = true
                        return true
                    }
                    return false
                }

                if needsWarning {
                    if parameters.topK != 0 {
                        self.log.warning("MLX: topK (\(parameters.topK, privacy: .public)) not supported by current GenerateParameters, skipping")
                    }
                    if parameters.minP != 0 {
                        self.log.warning("MLX: minP (\(parameters.minP, privacy: .public)) not supported by current GenerateParameters, skipping")
                    }
                    if parameters.repeatPenalty != 1.0 {
                        self.log.warning("MLX: repeatPenalty (\(parameters.repeatPenalty, privacy: .public)) not supported by current GenerateParameters, skipping")
                    }
                }

                let generateParameters = GenerateParameters(
                    maxTokens: parameters.maxTokens,
                    temperature: Float(parameters.temperature),
                    topP: Float(parameters.topP)
                )

                let start = Date()
                var tokensGenerated = 0
                var currentText = ""
                var hitMaxTokens = false

                if let nativeContainer = self.container as? ModelContainer {
                    // Build the canonical history once. Both the reuse
                    // check and the rebuild path consume the same value
                    // so they cannot drift.
                    let canonicalHistory = MLXChatInput.history(from: prompt)

                    let currentModelID = self.loadedModel?.id ?? "(none)"
                    let session: ChatSession = self.sessionLock.withLock {
                        let currentActive = self.activeSession

                        // Decide reuse vs rebuild. Log exactly one line per
                        // generation so multi-turn issues can be traced to
                        // the specific mismatch reason.
                        let discardReason: String?
                        if parameters.forceStateless {
                            discardReason = "forceStateless == true"
                        } else if let existing = currentActive {
                            if existing.modelID != currentModelID {
                                // Cached prefix was tokenised against a
                                // different vocab — never safe to reuse
                                // even on a matching conversationID.
                                discardReason = "different modelID (\(existing.modelID) → \(currentModelID))"
                            } else if existing.conversationID != conversationID {
                                discardReason = "different conversationID"
                            } else if existing.systemPrompt != prompt.systemPrompt {
                                discardReason = "different systemPrompt"
                            } else if !MLXChatInput.cachedPrefixMatches(
                                cached: existing.messages,
                                incoming: canonicalHistory
                            ) {
                                discardReason = canonicalHistory.count < existing.messages.count
                                    ? "history shorter than cached prefix"
                                    : "history token mismatch (formatting changed?)"
                            } else {
                                discardReason = nil
                            }
                        } else {
                            discardReason = "no cached session"
                        }

                        if discardReason == nil, let existing = currentActive {
                            self.log.info("MLX: KV cache reused — prefix match OK for \(conversationID, privacy: .public)")
                            return existing.session
                        }

                        // Rebuild path.
                        let reason = discardReason ?? "unknown"
                        self.log.info("MLX: KV cache discarded — mismatch (reason: \(reason, privacy: .public)) for \(conversationID, privacy: .public)")

                        let history: [Chat.Message] = canonicalHistory.map(MLXChatInput.toNative)
                        let newSession = ChatSession(
                            nativeContainer,
                            instructions: prompt.systemPrompt.isEmpty ? nil : prompt.systemPrompt,
                            history: history
                        )

                        // Stateless mode keeps the cached session field nil so
                        // the next turn also rebuilds; non-stateless caches it
                        // for prefix-reuse on the following turn.
                        if parameters.forceStateless {
                            self.activeSession = nil
                        } else {
                            self.activeSession = ActiveSession(
                                modelID: currentModelID,
                                conversationID: conversationID,
                                systemPrompt: prompt.systemPrompt,
                                messages: canonicalHistory,
                                session: newSession
                            )
                        }
                        return newSession
                    }

                    let lastTurn = MLXChatInput.lastTurn(from: prompt)

                    session.generateParameters = generateParameters
                    let responseStream = session.streamResponse(
                        to: lastTurn.content,
                        role: lastTurn.role,
                        images: [],
                        videos: []
                    )

                    var buffer = ""
                    var lastYieldTime = Date()

                    for try await piece in responseStream {
                        if Task.isCancelled { break }

                        // Per-token autoreleasepool drains the ObjC temporaries
                        // (MLXArray wrappers, intermediate NSString views) that
                        // MLX-Swift's C++ bridge creates for each decode step.
                        // Without this, the pool only drains when the run loop
                        // iterates — during a tight streaming await it may not
                        // get the chance for several hundred tokens, causing
                        // measurable memory creep on long replies.
                        //
                        // Buffer / yield logic stays OUTSIDE the pool so the
                        // 100 ms flush cadence and stop-sequence semantics are
                        // unchanged from before.
                        autoreleasepool {
                            tokensGenerated += 1
                            currentText += piece
                            buffer += piece
                        }

                        let now = Date()
                        if now.timeIntervalSince(lastYieldTime) >= 0.1 {
                            continuation.yield(.token(buffer))
                            buffer = ""
                            lastYieldTime = now
                        }

                        if tokensGenerated >= parameters.maxTokens {
                            hitMaxTokens = true
                            break
                        }

                        var shouldStop = false
                        for stopSeq in parameters.stopSequences {
                            if currentText.hasSuffix(stopSeq) {
                                shouldStop = true
                                break
                            }
                        }
                        if shouldStop { break }
                    }

                    if !buffer.isEmpty {
                        continuation.yield(.token(buffer))
                    }

                    self.sessionLock.withLock {
                        if !Task.isCancelled {
                            if self.activeSession?.conversationID == conversationID && self.activeSession?.session === session {
                                self.activeSession?.messages = prompt.messages
                                self.activeSession?.messages.append(RuntimeMessage(role: .assistant, content: currentText))
                            }
                        } else {
                            if self.activeSession?.session === session {
                                self.log.info("MLX: Session invalidated due to task cancellation for \(conversationID, privacy: .public)")
                                self.activeSession = nil
                            }
                        }
                    }

                } else {
                    self.log.info("MLX: Using stateless fallback generation")
                    var msgList: [[String: String]] = []
                    if !prompt.systemPrompt.isEmpty {
                        msgList.append(["role": "system", "content": prompt.systemPrompt])
                    }
                    for msg in prompt.messages {
                        let roleString: String = switch msg.role {
                        case .system: "system"
                        case .user: "user"
                        case .assistant: "assistant"
                        }
                        msgList.append(["role": roleString, "content": msg.content])
                    }

                    // Immutable let copy — safe to capture in @Sendable closure.
                    // Local tracking vars are returned as a tuple so the outer scope stays mutable-free.
                    let capturedMsgs = msgList
                    let fallbackResult: (Int, String, Bool) = try await container.perform { context in
                        let userInput = UserInput(
                            messages: capturedMsgs.map { $0.mapValues { $0 as any Sendable } }
                        )
                        let input = try await context.processor.prepare(input: userInput)

                        let genStream = try MLXLMCommon.generate(
                            input: input,
                            parameters: generateParameters,
                            context: context
                        )

                        var buffer = ""
                        var lastYieldTime = Date()
                        var localTokens = 0
                        var localText = ""
                        var localHit = false

                        for await generation in genStream {
                            if Task.isCancelled { break }
                            switch generation {
                            case .chunk(let text):
                                // Mirror the ChatSession path: per-token
                                // autoreleasepool to drain MLX C++ bridge
                                // temporaries. Buffer flush / stop checks
                                // stay outside the pool so cadence and
                                // stop-sequence behaviour are unchanged.
                                autoreleasepool {
                                    localTokens += 1
                                    localText += text
                                    buffer += text
                                }

                                let now = Date()
                                if now.timeIntervalSince(lastYieldTime) >= 0.1 {
                                    continuation.yield(.token(buffer))
                                    buffer = ""
                                    lastYieldTime = now
                                }

                                if localTokens >= parameters.maxTokens {
                                    localHit = true
                                    break
                                }
                                var stop = false
                                for s in parameters.stopSequences {
                                    if localText.hasSuffix(s) {
                                        stop = true
                                        break
                                    }
                                }
                                if stop { break }
                            case .info:
                                break
                            case .toolCall:
                                // Tool calls are surfaced through the
                                // higher-level routing runtime; the raw
                                // streaming path here ignores them so the
                                // model's own JSON tool-call wrapper can
                                // be re-parsed by `ToolCallEnvelope`.
                                break
                            @unknown default:
                                break
                            }
                        }

                        if !buffer.isEmpty {
                            continuation.yield(.token(buffer))
                        }

                        return (localTokens, localText, localHit)
                    }

                    tokensGenerated = fallbackResult.0
                    currentText = fallbackResult.1
                    hitMaxTokens = fallbackResult.2
                }

                let durationMs = Int(Date().timeIntervalSince(start) * 1000)
                let tps = durationMs > 0 ? (Double(tokensGenerated) / Double(durationMs)) * 1000.0 : 0.0

                // Update rolling tps + clear any prior failure now that
                // a successful generation has completed. Folded into one
                // lock acquisition with the busy-flag reset to keep the
                // critical section short.
                let modelID = self.loadedModel?.id ?? "(none)"
                self.sessionLock.withLock {
                    self.activeTask = nil
                    self.activeGenerationID = nil
                    self.isGenerating = false
                    self._lastGenerationError = nil
                    if tokensGenerated > 0 {
                        let prev = self.tpsAverage[modelID] ?? (mean: 0, n: 0)
                        let n = prev.n + 1
                        let mean = prev.mean + (tps - prev.mean) / Double(n)
                        self.tpsAverage[modelID] = (mean: mean, n: n)
                    }
                }

                let stats = RuntimeStats(
                    tokensGenerated: tokensGenerated,
                    tokensPerSecond: tps,
                    totalDurationMs: durationMs
                )

                let finishReason: RuntimeEvent.FinishReason =
                    Task.isCancelled ? .cancelled : (hitMaxTokens ? .length : .stop)

                // Single concise per-generation summary line. Aligned with
                // the llama.cpp side so log queries can grep both backends.
                let safeMode = HardwareCapabilities.shared.safeAttentionMode
                self.log.info(
                    "MLX generation: backend=mlx modelID=\(modelID, privacy: .public) tokens=\(tokensGenerated, privacy: .public) durationMs=\(durationMs, privacy: .public) tps=\(String(format: "%.1f", tps), privacy: .public) safeMode=\(safeMode, privacy: .public) reason=\(String(describing: finishReason), privacy: .public)"
                )

                continuation.yield(.finished(reason: finishReason, stats: stats))
                continuation.finish()

            } catch {
                let modelID = self.loadedModel?.id ?? "(none)"
                let failure = GenerationFailure.classify(error, modelID: modelID, backend: "mlx")
                self.sessionLock.withLock {
                    self.activeTask = nil
                    self.activeGenerationID = nil
                    self.isGenerating = false
                    self._lastGenerationError = failure
                }
                self.log.error("MLX generation: backend=mlx modelID=\(modelID, privacy: .public) failed kind=\(String(describing: failure.kind), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                continuation.finish(throwing: error)
            }
        }

        self.sessionLock.lock()
        self.activeTask = task
        self.sessionLock.unlock()

        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }

        return stream
    }

    func handleMemoryPressure() async {
        self.log.warning("MLX: Memory pressure received — unloading model")
        await unload()
    }

    func handleBackground() async {
        // Policy: MLX keeps weights resident across background transitions.
        // Re-warming MLX after a background→foreground takes 10–60 s on
        // iPhone (Metal pipeline compile + tokenizer reload), which is
        // worse for the user than the OS occasionally re-claiming the
        // suspended app. Memory-pressure / thermal-critical paths *do*
        // unload via `handleMemoryPressure` / `RuntimeManager`.
        self.log.info("MLX runtime: backgrounded — keeping weights resident (policy)")
    }
}

// MARK: - Diagnostic Helpers

private extension Error {
    /// Returns a readable description for diagnostic logging.
    /// TokenizerError and HubClientError are internal to their modules so we
    /// use String(describing:) which includes the type name and associated values.
    var mlxDescriptiveMessage: String {
        String(describing: self)
    }
}

// MARK: - GenerationFailure

/// User-facing snapshot of the last failed generation. Captured by both
/// MLX and llama.cpp runtimes so the Model Info sheet can show a short,
/// human-readable explanation without leaking low-level symbols.
struct GenerationFailure: Sendable, Equatable {
    /// Coarse-grained category so the UI can group / colour reasons.
    enum Kind: Sendable, Equatable {
        case outOfMemory
        case cancelled
        case templateError
        case backendError
        case other
    }
    let modelID: String
    let backend: String          // "mlx" / "llama.cpp"
    let kind: Kind
    /// Already-localised, single sentence. Safe to show in UI.
    let message: String
    let occurredAt: Date

    /// Classify an arbitrary error into a `GenerationFailure`.
    /// Used by both runtimes — kept in MLX file to share the implementation
    /// (Swift modules; no separate file needed for two call sites).
    static func classify(
        _ error: Error,
        modelID: String,
        backend: String
    ) -> GenerationFailure {
        let raw = error.localizedDescription
        let kind: Kind
        let message: String
        let lower = raw.lowercased()
        if (error as? RuntimeError) == .outOfMemory || lower.contains("out of memory") || lower.contains("oom") {
            kind = .outOfMemory
            message = "Out of memory while running this model. Try a smaller / more aggressively quantised model, or switch the performance profile to Conservative."
        } else if error is CancellationError || lower.contains("cancel") {
            kind = .cancelled
            message = "Generation was cancelled before it finished."
        } else if lower.contains("template") || lower.contains("tokenizer") {
            kind = .templateError
            message = "The model's chat template could not be applied. Re-download the model or pick a different one."
        } else if lower.contains("llama_decode") || lower.contains("metal") || lower.contains("mlx") {
            kind = .backendError
            message = "Runtime error in the inference engine: \(raw)"
        } else {
            kind = .other
            message = raw
        }
        return GenerationFailure(
            modelID: modelID,
            backend: backend,
            kind: kind,
            message: message,
            occurredAt: Date()
        )
    }
}

// MARK: - Canonical MLX chat-input helper

/// Single source of truth for converting a `RuntimePrompt` into the
/// `(systemPrompt, history, lastUserContent, lastRole)` quadruple
/// consumed by `MLXLLM.ChatSession`.
///
/// **Why this exists**: the KV-cache reuse decision and the new-session
/// constructor both need the same canonical view of "what is the history
/// for this turn?". Earlier versions of the runtime duplicated that
/// logic in two places — drift between the two manifested as KV cache
/// invalidation that looked like "history token mismatch" even when
/// nothing had actually changed.
enum MLXChatInput {

    /// History = everything except the last message. The last message is
    /// fed to `ChatSession.streamResponse(to:role:)` separately.
    static func history(from prompt: RuntimePrompt) -> [RuntimeMessage] {
        Array(prompt.messages.dropLast())
    }

    /// The (content, role) tuple driven into `streamResponse`. When the
    /// prompt has no messages we fall back to an empty assistant turn so
    /// the call site can still finish a stream cleanly.
    static func lastTurn(from prompt: RuntimePrompt) -> (content: String, role: Chat.Message.Role) {
        guard let last = prompt.messages.last else { return ("", .assistant) }
        switch last.role {
        case .system:    return (last.content, .system)
        case .user:      return (last.content, .user)
        case .assistant: return (last.content, .assistant)
        }
    }

    /// Maps a single canonical `RuntimeMessage` into `Chat.Message`.
    /// Used to seed `ChatSession.history`. The mapping is intentionally
    /// 1:1 — any normalisation (e.g. trimming) must happen upstream in
    /// the prompt-assembly service so reuse equality checks see the same
    /// strings on both sides.
    static func toNative(_ msg: RuntimeMessage) -> Chat.Message {
        switch msg.role {
        case .system:    return .system(msg.content)
        case .user:      return .user(msg.content)
        case .assistant: return .assistant(msg.content)
        }
    }

    /// Strict equality used by the KV-cache reuse check. Compares **both**
    /// role and content, in order. The cached prefix must be a strict
    /// prefix of the incoming history — `cached.count` ≤ `incoming.count`
    /// and every position equal — otherwise the KV cache is invalid.
    static func cachedPrefixMatches(
        cached: [RuntimeMessage],
        incoming: [RuntimeMessage]
    ) -> Bool {
        guard cached.count <= incoming.count else { return false }
        return incoming.prefix(cached.count).elementsEqual(cached) {
            $0.role == $1.role && $0.content == $1.content
        }
    }
}
