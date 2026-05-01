import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import os

/// Future MLX-backed local runtime for Apple Silicon.
///
///
/// This implementation relies on `MLXLMCommon` and its native huggingface
/// caching mechanism. State is isolated to the ModelContainer's actor.
/// the heavy lifting (model loading, weight conversion, KV-cache)
/// for Phase 2.
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
    
    /// Protocol-required load (no progress). Delegates to `loadWithProgress` with a no-op handler.
    func load(model: LocalModel) async throws {
        try await loadWithProgress(model: model, progressHandler: nil)
    }
    
    /// Extended load that accepts an optional progress callback.
    ///
    /// Two-phase load:
    /// 1. **Download** (cold cache): Fetches weights from Hugging Face Hub via `HubApiDownloader`.
    ///    Reports real `Foundation.Progress` fractions to `progressHandler(.downloading(fraction:))`.
    /// 2. **Prepare** (warm cache or after download): Loads weights into memory and compiles the
    ///    Metal compute pipeline. This phase is indeterminate — `progressHandler(.preparing)` is
    ///    fired once and no fraction is reported.
    ///
    /// ## Cancellation
    /// Both phases are Swift `async`, so `Task.cancel()` propagates cooperatively.
    /// A cancelled download may leave a partial cache; Phase 3's tri-state detection
    /// classifies it as `.partial` (safe, maps to `.notInstalled`).
    func loadWithProgress(
        model: LocalModel,
        progressHandler: (@Sendable (MLXLoadPhase) -> Void)?
    ) async throws {
        sessionLock.lock()
        if activeTask != nil {
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
        
        // Track whether the download phase has completed so we can transition to .preparing.
        var downloadDone = false
        
        let progressAdapter: @Sendable (Progress) -> Void = { progress in
            if progress.fractionCompleted < 1.0 || !downloadDone {
                progressHandler?(.downloading(fraction: max(0, min(1, progress.fractionCompleted))))
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
            
            // Download is done (or was skipped for warm cache). Signal transition to init phase.
            downloadDone = true
            log.debug("MLX: Download/cache complete for '\(repoId, privacy: .public)', now initializing")
            progressHandler?(.preparing)
            
            // NOTE: loadModelContainer returns only after the model is fully initialized.
            // The .preparing signal was fired above to give the UI an honest state between
            // download completion and this function returning.
            
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
        activeSession = nil
        container = nil
        sessionLock.unlock()
        loadedModel = nil
    }
    
    func invalidateSession(for conversationID: UUID) async {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        
        if activeSession?.conversationID == conversationID {
            log.info("MLX: Invalidating session for conversation \(conversationID, privacy: .public) (manual/reset)")
            activeSession = nil
        }
        
        if activeGenerationID == conversationID {
            log.info("MLX: Cancelling active generation for conversation \(conversationID, privacy: .public) due to invalidation")
            activeTask?.cancel()
            activeTask = nil
            activeGenerationID = nil
        }
    }
    
    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            let conversationID = parameters.conversationID ?? UUID()
            
            self.sessionLock.lock()
            if self.activeTask != nil {
                self.sessionLock.unlock()
                log.warning("MLX: Generation/load already in progress — blocking concurrent request for \(conversationID, privacy: .public)")
                continuation.finish(throwing: RuntimeError.generationInProgress)
                return
            }
            self.activeGenerationID = conversationID
            self.sessionLock.unlock()
            
            let task = Task {
                do {
                    guard let container = self.container else {
                        continuation.finish(throwing: RuntimeError.noModelLoaded)
                        return
                    }
                    
                    let generateParameters = GenerateParameters(
                        maxTokens: parameters.maxTokens,
                        temperature: Float(parameters.temperature),
                        topP: Float(parameters.topP)
                    )
                    
                    let conversationID = parameters.conversationID ?? UUID()
                    
                    let start = Date()
                    var tokensGenerated = 0
                    var currentText = ""
                    
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
                            // Reuse
                            session = existing.session
                            log.debug("MLX: Reusing existing session for \(conversationID, privacy: .public)")
                        } else {
                            // Reset/Re-hydrate
                            if currentActive != nil {
                                log.info("MLX: Session mismatch or reset — starting fresh for \(conversationID, privacy: .public)")
                            }
                            
                            // Helper to convert RuntimeMessage to Chat.Message
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
                            
                            if tokensGenerated >= parameters.maxTokens { break }
                            
                            // Check stop sequences
                            var shouldStop = false
                            for stopSeq in parameters.stopSequences {
                                if currentText.hasSuffix(stopSeq) {
                                    shouldStop = true
                                    break
                                }
                            }
                            if shouldStop { break }
                        }
                        
                        // Update session history on success, or invalidate on cancellation
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
                        // --- STATELESS FALLBACK (Tests or non-native container) ---
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
                                
                                if tokensGenerated >= parameters.maxTokens { return .stop }
                                for stopSeq in parameters.stopSequences {
                                    if currentText.hasSuffix(stopSeq) { return .stop }
                                }
                                return .more
                            }
                        }
                    }
                    
                    // Final cleanup: clear task tracking
                    self.sessionLock.lock()
                    if self.activeTask === task {
                        self.activeTask = nil
                        self.activeGenerationID = nil
                    }
                    self.sessionLock.unlock()
                    
                    let durationMs = Int(Date().timeIntervalSince(start) * 1000)
                    let tps = durationMs > 0 ? (Double(tokensGenerated) / Double(durationMs)) * 1000.0 : 0.0
                    
                    let stats = RuntimeStats(
                        tokensGenerated: tokensGenerated,
                        tokensPerSecond: tps,
                        totalDurationMs: durationMs
                    )
                    
                    continuation.yield(.finished(reason: Task.isCancelled ? .cancelled : .stop, stats: stats))
                    continuation.finish()
                    
                } catch {
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
