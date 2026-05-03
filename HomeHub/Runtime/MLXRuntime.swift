import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
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
/// what SPM resolves (`mlx-swift`, `mlx-swift-lm`, `swift-transformers`,
/// `Hub`, `Tokenizers`). It runs out-of-the-box on a fresh checkout, no
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

    private var container: any MLXModelContainer?
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

    init(loader: any MLXLoader = DefaultMLXLoader()) {
        self.loader = loader
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
        sessionLock.lock()
        if isGenerating {
            sessionLock.unlock()
            throw RuntimeError.generationInProgress
        }
        sessionLock.unlock()

        log.info("MLX: Preparing to load model '\(model.displayName, privacy: .public)'")

        guard let repoId = model.repoId else {
            throw RuntimeError.incompatibleModel(
                "MLX models must be hosted on Hugging Face. Invalid URL: \(model.downloadURL.absoluteString)"
            )
        }

        let config = ModelConfiguration(id: repoId)
        let downloader = HubApiDownloader()
        let tokenizerLoader = SwiftTransformersTokenizerLoader()

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

        log.debug("MLX: Starting load for '\(repoId, privacy: .public)'")
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
            sessionLock.lock()
            activeSession = nil
            sessionLock.unlock()

            let duration = Int(Date().timeIntervalSince(start) * 1000)
            self.loadedModel = model
            await telemetry.emit(.modelLoaded(handle: ModelHandle(from: model), durationMs: duration))
            log.info("MLX: Model '\(model.displayName, privacy: .public)' loaded in \(duration)ms")
        } catch is CancellationError {
            log.info("MLX: Load cancelled for '\(repoId, privacy: .public)'")
            throw CancellationError()
        } catch {
            log.error("MLX: Failed to load model container: \(error.localizedDescription, privacy: .public)")
            throw RuntimeError.initializationFailed("Failed to load MLX model: \(error.localizedDescription)")
        }
    }

    func unload() async {
        log.info("MLX: Unloading model (manual or policy-driven)")
        sessionLock.lock()
        activeTask?.cancel()
        activeTask = nil
        activeGenerationID = nil
        isGenerating = false
        activeSession = nil
        container = nil
        sessionLock.unlock()
        loadedModel = nil
    }

    func invalidateSession(for conversationID: UUID) async {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        if activeSession?.conversationID == conversationID {
            log.info("MLX: Invalidating session for conversation \(conversationID, privacy: .public)")
            activeSession = nil
        }

        if activeGenerationID == conversationID {
            log.info("MLX: Cancelling active generation for conversation \(conversationID, privacy: .public) due to invalidation")
            activeTask?.cancel()
            activeTask = nil
            activeGenerationID = nil
            isGenerating = false
        }
    }

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            // Use a single conversationID throughout this closure and the task body.
            let conversationID = parameters.conversationID ?? UUID()

            // Atomically check and set isGenerating. Both happen under the same
            // lock acquisition, eliminating the TOCTOU race from split check/set.
            self.sessionLock.lock()
            guard !self.isGenerating else {
                self.sessionLock.unlock()
                log.warning("MLX: Generation/load already in progress — blocking concurrent request for \(conversationID, privacy: .public)")
                continuation.finish(throwing: RuntimeError.generationInProgress)
                return
            }
            self.isGenerating = true
            self.activeGenerationID = conversationID
            self.sessionLock.unlock()

            let task = Task {
                do {
                    guard let container = self.container else {
                        continuation.finish(throwing: RuntimeError.noModelLoaded)
                        self.sessionLock.lock()
                        self.isGenerating = false
                        self.activeGenerationID = nil
                        self.sessionLock.unlock()
                        return
                    }

                    // NOTE: MLXLMCommon.GenerateParameters (current version) only exposes
                    // maxTokens, temperature, and topP. The following RuntimeParameters
                    // fields are accepted by the contract but NOT forwarded to the MLX
                    // backend: topK, minP, repeatPenalty, repeatPenaltyLastN,
                    // frequencyPenalty, presencePenalty.
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
                        // --- NATIVE PATH (ChatSession) ---
                        self.sessionLock.lock()
                        let currentActive = self.activeSession
                        let session: ChatSession

                        if let existing = currentActive,
                           existing.conversationID == conversationID,
                           existing.systemPrompt == prompt.systemPrompt,
                           prompt.messages.count >= existing.messages.count,
                           prompt.messages.prefix(existing.messages.count).elementsEqual(existing.messages, by: { $0.content == $1.content && $0.role == $1.role }) {
                            session = existing.session
                            log.debug("MLX: Reusing existing session for \(conversationID, privacy: .public)")
                        } else {
                            if currentActive != nil {
                                log.info("MLX: Session mismatch or reset — starting fresh for \(conversationID, privacy: .public)")
                            }

                            let toNativeMessage: (RuntimeMessage) -> Chat.Message = { msg in
                                switch msg.role {
                                case .system:    return .system(msg.content)
                                case .user:      return .user(msg.content)
                                case .assistant: return .assistant(msg.content)
                                }
                            }

                            let history: [Chat.Message] = prompt.messages.dropLast().map(toNativeMessage)
                            session = ChatSession(
                                nativeContainer,
                                instructions: prompt.systemPrompt.isEmpty ? nil : prompt.systemPrompt,
                                history: history
                            )

                            self.activeSession = ActiveSession(
                                conversationID: conversationID,
                                systemPrompt: prompt.systemPrompt,
                                messages: Array(prompt.messages.dropLast()),
                                session: session
                            )
                        }
                        self.sessionLock.unlock()

                        let lastMessage = prompt.messages.last
                        let lastContent = lastMessage?.content ?? ""
                        let lastRole: Chat.Message.Role = switch lastMessage?.role {
                        case .system: .system
                        case .user: .user
                        case .assistant, .none: .assistant
                        }

                        let stream = session.streamResponse(
                            to: lastContent,
                            role: lastRole,
                            parameters: generateParameters
                        )

                        for try await piece in stream {
                            if Task.isCancelled { break }

                            tokensGenerated += 1
                            currentText += piece
                            continuation.yield(.token(piece))

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

                        self.sessionLock.lock()
                        if !Task.isCancelled {
                            if self.activeSession?.conversationID == conversationID && self.activeSession?.session === session {
                                self.activeSession?.messages = prompt.messages
                                self.activeSession?.messages.append(RuntimeMessage(role: .assistant, content: currentText))
                            }
                        } else {
                            if self.activeSession?.session === session {
                                log.info("MLX: Session invalidated due to task cancellation for \(conversationID, privacy: .public)")
                                self.activeSession = nil
                            }
                        }
                        self.sessionLock.unlock()

                    } else {
                        // --- STATELESS FALLBACK (tests / non-native container) ---
                        log.info("MLX: Using stateless fallback generation")
                        var messages: [[String: String]] = []
                        if !prompt.systemPrompt.isEmpty {
                            messages.append(["role": "system", "content": prompt.systemPrompt])
                        }
                        for msg in prompt.messages {
                            let roleString: String = switch msg.role {
                            case .system: "system"
                            case .user: "user"
                            case .assistant: "assistant"
                            }
                            messages.append(["role": roleString, "content": msg.content])
                        }

                        try await container.perform { context in
                            let userInput = UserInput(messages: messages.map { message in
                                var dict: [String: Any] = [:]
                                for (k, v) in message { dict[k] = v }
                                return dict
                            })
                            let input = try await context.processor.prepare(input: userInput)

                            _ = try MLXLMCommon.generate(
                                input: input,
                                parameters: generateParameters,
                                context: context
                            ) { tokens in
                                if Task.isCancelled { return .stop }

                                tokensGenerated += 1
                                let newText = context.tokenizer.decode(tokenIds: tokens)

                                if newText.count > currentText.count {
                                    let chunk = String(newText.dropFirst(currentText.count))
                                    currentText = newText
                                    continuation.yield(.token(chunk))
                                }

                                if tokensGenerated >= parameters.maxTokens {
                                    hitMaxTokens = true
                                    return .stop
                                }
                                for stopSeq in parameters.stopSequences {
                                    if currentText.hasSuffix(stopSeq) { return .stop }
                                }
                                return .more
                            }
                        }
                    }

                    // Final cleanup: reset busy state.
                    self.sessionLock.lock()
                    if self.activeTask === task {
                        self.activeTask = nil
                        self.activeGenerationID = nil
                        self.isGenerating = false
                    }
                    self.sessionLock.unlock()

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
                    self.sessionLock.lock()
                    if self.activeTask === task {
                        self.activeTask = nil
                        self.activeGenerationID = nil
                        self.isGenerating = false
                    }
                    self.sessionLock.unlock()
                    log.error("MLX: Generation failed: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }

            self.sessionLock.lock()
            self.activeTask = task
            self.sessionLock.unlock()

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func handleMemoryPressure() async {
        log.warning("MLX: Memory pressure received — unloading model")
        await unload()
    }

    func handleBackground() async {
        log.info("MLX: App backgrounded")
    }
}
