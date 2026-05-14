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

    #if DEBUG
    var internalActiveSessionConversationID: UUID? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return activeSession?.conversationID
    }
    #endif

    private var container: (any MLXModelContainer)?
    private var activeTask: Task<Void, Never>?
    private var activeGenerationID: UUID?
    /// Single authoritative "busy" flag. Protected by sessionLock.
    private var isGenerating: Bool = false
    private let sessionLock = NSLock()

    private struct ActiveSession: @unchecked Sendable {
        let conversationID: UUID
        let systemPrompt: String
        var messages: [RuntimeMessage]
        let session: ChatSession
    }
    private var activeSession: ActiveSession?

    private let loader: any MLXLoader

    /// Suppresses repeat warnings about unsupported sampler parameters so
    /// they appear only once per model load rather than on every generation.
    private var hasLoggedSamplerWarnings = false

    init(loader: any MLXLoader = DefaultMLXLoader()) {
        self.loader = loader
        // Configure MLX GPU memory cache limit based on device memory tier.
        // Prevents unbounded GPU buffer accumulation during multi-turn conversations.
        // Tight devices (iPhone SE): 25 MB — preserve stability above all.
        // Moderate devices (iPhone 13–15): 50 MB — balance caching + safety.
        // Generous devices (iPhone 16 Pro, iPad): 128 MB — maximize cache benefit.
        let cacheLimitBytes = DeviceMemoryProvider.shared.profile.mlxGPUCacheLimitBytes
        MLX.Memory.cacheLimit = Int(cacheLimitBytes)
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
            self.log.info("MLX: Load cancelled for '\(repoId, privacy: .public)'")
            throw CancellationError()
        } catch {
            let descriptiveError = error.mlxDescriptiveMessage
            self.log.error("MLX: Failed to load model '\(repoId, privacy: .public)': \(descriptiveError, privacy: .public)")
            
            throw RuntimeError.initializationFailed("Failed to load MLX model: \(descriptiveError)")
        }
    }

    func unload() async {
        self.log.info("MLX: Unloading model (manual or policy-driven)")
        sessionLock.withLock {
            activeTask?.cancel()
            activeTask = nil
            activeGenerationID = nil
            isGenerating = false
            activeSession = nil
            container = nil
        }
        loadedModel = nil
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
                    let session: ChatSession = self.sessionLock.withLock {
                        let currentActive = self.activeSession

                        if let existing = currentActive,
                           existing.conversationID == conversationID,
                           existing.systemPrompt == prompt.systemPrompt,
                           prompt.messages.count >= existing.messages.count,
                           prompt.messages.prefix(existing.messages.count).elementsEqual(existing.messages, by: { $0.content == $1.content && $0.role == $1.role }) {
                            self.log.debug("MLX: Reusing existing session for \(conversationID, privacy: .public)")
                            return existing.session
                        } else {
                            if currentActive != nil {
                                self.log.info("MLX: Session mismatch or reset — starting fresh for \(conversationID, privacy: .public)")
                            }

                            let toNativeMessage: (RuntimeMessage) -> Chat.Message = { msg in
                                switch msg.role {
                                case .system: return .system(msg.content)
                                case .user: return .user(msg.content)
                                case .assistant: return .assistant(msg.content)
                                }
                            }

                            let history: [Chat.Message] = prompt.messages.dropLast().map(toNativeMessage)
                            let newSession = ChatSession(
                                nativeContainer,
                                instructions: prompt.systemPrompt.isEmpty ? nil : prompt.systemPrompt,
                                history: history
                            )

                            self.activeSession = ActiveSession(
                                conversationID: conversationID,
                                systemPrompt: prompt.systemPrompt,
                                messages: Array(prompt.messages.dropLast()),
                                session: newSession
                            )
                            return newSession
                        }
                    }

                    let lastMessage = prompt.messages.last
                    let lastContent = lastMessage?.content ?? ""
                    let lastRole: Chat.Message.Role = switch lastMessage?.role {
                    case .system: .system
                    case .user: .user
                    case .assistant, .none: .assistant
                    }

                    session.generateParameters = generateParameters
                    let responseStream = session.streamResponse(
                        to: lastContent,
                        role: lastRole,
                        images: [],
                        videos: []
                    )

                    var buffer = ""
                    var lastYieldTime = Date()

                    for try await piece in responseStream {
                        if Task.isCancelled { break }

                        tokensGenerated += 1
                        currentText += piece
                        buffer += piece

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
                                localTokens += 1
                                localText += text
                                buffer += text

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

                self.sessionLock.withLock {
                    self.activeTask = nil
                    self.activeGenerationID = nil
                    self.isGenerating = false
                }

                let durationMs = Int(Date().timeIntervalSince(start) * 1000)
                let tps = durationMs > 0 ? (Double(tokensGenerated) / Double(durationMs)) * 1000.0 : 0.0

                let stats = RuntimeStats(
                    tokensGenerated: tokensGenerated,
                    tokensPerSecond: tps,
                    totalDurationMs: durationMs
                )

                let finishReason: RuntimeEvent.FinishReason =
                    Task.isCancelled ? .cancelled : (hitMaxTokens ? .length : .stop)
                continuation.yield(.finished(reason: finishReason, stats: stats))
                continuation.finish()

            } catch {
                self.sessionLock.withLock {
                    self.activeTask = nil
                    self.activeGenerationID = nil
                    self.isGenerating = false
                }
                self.log.error("MLX: Generation failed: \(error.localizedDescription, privacy: .public)")
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
        self.log.info("MLX: App backgrounded")
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
