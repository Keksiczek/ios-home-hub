import Foundation
import os

// MARK: - Unload policy

extension LlamaCppRuntime {
    /// Governs when the runtime automatically unloads the active model
    /// in response to device lifecycle events.
    ///
    /// Set `unloadPolicy` before calling `load()`. The runtime evaluates
    /// the policy inside `handleMemoryPressure()` and `handleBackground()`.
    ///
    /// **Default**: `.onBackgroundOrMemoryPressure` — safest choice for
    /// production; reclaims memory aggressively to avoid OS termination.
    enum UnloadPolicy: Sendable {
        /// Never unload automatically; only when `unload()` is called explicitly.
        /// Use in tests or when the caller wants full control over the lifecycle.
        case manual

        /// Unload when the app moves to the background (`handleBackground()`).
        /// Memory-pressure warnings are ignored.
        case onBackground

        /// Unload on background **and** on memory-pressure notifications.
        /// Recommended for production: the model is large and will be reloaded
        /// on foreground when the user resumes a conversation.
        case onBackgroundOrMemoryPressure
    }
}

// MARK: - LlamaCppRuntime

/// V1 preferred local runtime, backed by `llama.cpp` compiled as an
/// xcframework with the Metal backend enabled.
///
/// ## Architecture
///
/// `LlamaCppRuntime` is a thin façade that:
/// 1. Conforms to `LocalLLMRuntime` — the only interface the rest of the
///    app ever touches (via `RuntimeManager`).
/// 2. Delegates all mutable C++ state to `LlamaRuntimeActor`.
///    No `NSLock` needed anywhere.
/// 3. Provides a deterministic **generate × unload contract** via
///    `GenerationCancellationToken` (see below).
/// 4. Emits structured `RuntimeTelemetryEvent`s for load time, TTFT, and
///    tokens/sec to all subscribers of `telemetry`.
///
/// See `LlamaContextHandle.swift` for xcframework integration instructions.
///
/// ## generate() × unload() contract
///
/// When `unload()` is called while a generation is running:
/// 1. The actor's `currentCancellationToken` is cancelled.
/// 2. The generation Task checks `token.isCancelled` before each token.
/// 3. On seeing `true` it yields `.finished(reason: .cancelled, stats: ...)`
///    and returns — **without calling back into C++**.
/// 4. The caller (UI / `ConversationService`) receives a clean stream
///    termination. Exactly like user-initiated `Task` cancellation.
///
/// **At most one extra token** can be decoded after `unload()` is called —
/// the one whose decode started before the cancel flag was observed. That
/// token is discarded (not yielded to the caller). Subsequent loop
/// iterations see `isCancelled = true` and stop.
///
/// ## loadedModel consistency
///
/// `loadedModel` is a sync-accessible mirror of the actor's authoritative
/// state. It is written only from `load()` / `unload()` call sites, both
/// of which are invoked from `RuntimeManager` on the `@MainActor`. Reads
/// from other actors (e.g. `MemoryExtractionService`) see a value that is
/// at most one suspension-point stale — acceptable for the
/// "is a model loaded?" guard. For guaranteed consistency, use
/// `currentModel() async`.
///
/// `@unchecked Sendable` acknowledges the sync mirror pattern: the compiler
/// cannot verify the write/read concurrency, but we have established the
/// invariant manually (write path is always `@MainActor`).
final class LlamaCppRuntime: LocalLLMRuntime, @unchecked Sendable {

    let identifier = "llama.cpp"

    // MARK: - Telemetry (first-class citizen)

    /// Subscribe to receive structured `RuntimeTelemetryEvent`s.
    ///
    /// ```swift
    /// let (stream, id) = await runtime.telemetry.subscribe()
    /// Task {
    ///     for await event in stream { handle(event) }
    /// }
    /// // Later: await runtime.telemetry.unsubscribe(id: id)
    /// ```
    let telemetry = RuntimeTelemetry()

    // MARK: - Unload policy

    /// Controls automatic unloading on lifecycle events.
    /// Default: `.onBackgroundOrMemoryPressure`.
    var unloadPolicy: UnloadPolicy = .onBackgroundOrMemoryPressure

    // MARK: - State

    /// Owns the C++ context and model info; serialises all mutations.
    private let runtimeActor = LlamaRuntimeActor()

    /// Sync-accessible cache — see class-level doc for threading contract.
    /// Not the authoritative source of truth; use `currentModel() async` for
    /// guaranteed-consistent reads.
    private var _loadedModel: LocalModel?

    private let log = Logger(subsystem: "HomeHub", category: "LlamaCppRuntime")

    // MARK: - LocalLLMRuntime

    var loadedModel: LocalModel? { _loadedModel }

    // MARK: - Load

    func load(model: LocalModel) async throws {
        guard case .installed(let url) = model.installState else {
            throw RuntimeError.modelNotInstalled
        }

        // Reject stub files and obviously-invalid GGUFs before handing off to
        // the C++ bridge. A stub created in dev/mock mode ("STUB_MODEL") will be
        // ~10 bytes and won't have the GGUF magic header.
        try Self.validateGGUFFile(at: url)

        let started = Date()
        do {
            try await runtimeActor.load(model: model, path: url.path)
        } catch let runtimeError as RuntimeError {
            throw runtimeError
        } catch {
            throw RuntimeError.underlying(error.localizedDescription)
        }

        _loadedModel = model

        let loadMs = Int(Date().timeIntervalSince(started) * 1_000)
        let handle = ModelHandle(from: model)

        await telemetry.emit(.modelLoaded(handle: handle, durationMs: loadMs))
        log.info("Model loaded: '\(model.displayName, privacy: .public)' in \(loadMs)ms")
        #if DEBUG
        print("[LlamaCppRuntime] ✓ '\(model.displayName)' loaded in \(loadMs)ms")
        #endif
    }

    // MARK: - Unload (protocol)

    func unload() async {
        await unload(reason: .manual)
    }

    // MARK: - Session invalidation

    /// Removes the KV-cache session record for `conversationID`.
    /// Call when the user deletes a conversation so stale tokens don't
    /// occupy memory and don't mislead the prefix-match logic on reuse.
    func invalidateSession(for conversationID: UUID) async {
        await runtimeActor.removeSession(for: conversationID)
    }

    // MARK: - Generate

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        let actor    = runtimeActor
        let log      = log
        let telemetry = telemetry
        let requestID = UUID()

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                // --- Borrow context + token atomically (single actor hop) ---
                let ctx: LlamaContextHandle
                let generationToken: GenerationCancellationToken
                do {
                    (ctx, generationToken) = try await actor.borrowForGeneration()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                // Emit generationStarted only after successful borrow so
                // requestID is only surfaced when we know we have a context.
                let loadedModel = await actor.loadedModel
                let handle = loadedModel.map { ModelHandle(from: $0) }

                if let handle {
                    await telemetry.emit(.generationStarted(requestID: requestID, handle: handle))
                }

                // Pass the model family so ChatTemplate selects the correct format.
                // Llama 3.x uses header tokens; Qwen/Phi use ChatML (<|im_start|>).
                let renderedPrompt = ChatTemplate.render(prompt, family: loadedModel?.family ?? "")
                let started = Date()
                var tokens = 0
                var firstTokenDate: Date? = nil

                // Fetch any existing KV-cache session for this conversation so we
                // can pass the cached token array to stream() for prefix reuse.
                let convID = parameters.conversationID
                let cachedTokens: [Int32]
                if let convID, let sess = await actor.session(for: convID) {
                    cachedTokens = sess.cachedPromptTokens
                } else {
                    cachedTokens = []
                }
                let cacheBox = StreamCacheBox()

                do {
                    let stream = try ctx.stream(
                        prompt: renderedPrompt,
                        maxTokens: parameters.maxTokens,
                        temperature: Float(parameters.temperature),
                        topP: Float(parameters.topP),
                        stopSequences: parameters.stopSequences,
                        cachedTokens: cachedTokens,
                        cacheBox: cacheBox
                    )

                    for try await piece in stream {
                        // --- Cancellation check (unload OR Task cancel) ---
                        // Checked BEFORE yielding to ensure:
                        // (a) No token is sent to caller after unload().
                        // (b) At most one extra token decode (the one in flight
                        //     when the cancel flag was set) before we stop.
                        if Task.isCancelled || generationToken.isCancelled {
                            let stats = Self.makeStats(tokens: tokens, started: started)
                            continuation.yield(.finished(reason: .cancelled, stats: stats))
                            continuation.finish()
                            await telemetry.emit(.generationCancelled(
                                requestID: requestID, partialStats: stats
                            ))
                            return
                        }

                        // --- First-token latency ---
                        if firstTokenDate == nil {
                            firstTokenDate = Date()
                            let ttftMs = Int(firstTokenDate!.timeIntervalSince(started) * 1_000)
                            log.debug("TTFT: \(ttftMs)ms (request \(requestID, privacy: .public))")
                            await telemetry.emit(.firstToken(requestID: requestID, latencyMs: ttftMs))
                            #if DEBUG
                            print("[LlamaCppRuntime] TTFT: \(ttftMs)ms")
                            #endif
                        }

                        tokens += 1
                        continuation.yield(.token(piece))
                    }

                    // Persist the prompt token sequence so the next turn for the
                    // same conversation can skip re-evaluating the shared prefix.
                    if let convID, !cacheBox.finalPromptTokens.isEmpty {
                        let updated = ConversationRuntimeSession(
                            conversationID: convID,
                            cachedPromptTokens: cacheBox.finalPromptTokens
                        )
                        await actor.updateSession(updated)
                    }

                    let stats = Self.makeStats(tokens: tokens, started: started)
                    log.info(
                        "Done: \(stats.tokensGenerated) tokens @ \(String(format: "%.1f", stats.tokensPerSecond), privacy: .public) t/s"
                    )
                    #if DEBUG
                    print(
                        "[LlamaCppRuntime] \(stats.tokensGenerated) tokens " +
                        "@ \(String(format: "%.1f", stats.tokensPerSecond)) t/s " +
                        "(\(stats.totalDurationMs)ms)"
                    )
                    #endif
                    await telemetry.emit(.generationFinished(
                        requestID: requestID, stats: stats, reason: .stop
                    ))
                    continuation.yield(.finished(reason: .stop, stats: stats))
                    continuation.finish()

                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Lifecycle hooks

    /// Unloads the model in response to a memory-pressure notification.
    ///
    /// Call this from a `UIApplication.didReceiveMemoryWarningNotification`
    /// observer. Respects `unloadPolicy`: no-op when policy is `.manual`.
    ///
    /// Wired into the App lifecycle via `AppContainer.handleMemoryPressure()`,
    /// which is invoked from `HomeHubApp.swift`'s memory-warning observer.
    func handleMemoryPressure() async {
        guard self.unloadPolicy == .onBackgroundOrMemoryPressure else { return }
        await telemetry.emit(.memoryPressureReceived)
        log.warning("Memory pressure — unloading model.")
        await unload(reason: .memoryPressure)
    }

    /// Unloads the model when the app enters the background.
    ///
    /// Wired into the App lifecycle via `AppContainer.handleScenePhaseChange(_:)`,
    /// which is invoked from `HomeHubApp.swift`'s `.onChange(of: scenePhase)` observer.
    func handleBackground() async {
        // Emit before the policy check so diagnostics can verify the event
        // was received even when policy is .manual (no unload happens).
        await telemetry.emit(.backgroundEventReceived)
        guard self.unloadPolicy != .manual else { return }
        log.info("App backgrounded — unloading model per policy '\(String(describing: self.unloadPolicy))'.")
        await unload(reason: .appBackground)
    }

    // MARK: - Authoritative async model access

    /// Returns the authoritative loaded model directly from the actor.
    ///
    /// Prefer this over `loadedModel` in async contexts where you need a
    /// guaranteed-consistent snapshot — for example, immediately before
    /// starting a generation to avoid a race with a concurrent `unload()`.
    func currentModel() async -> LocalModel? {
        await runtimeActor.loadedModel
    }

    // MARK: - Private helpers

    private func unload(reason: UnloadReason) async {
        guard let currentModel = _loadedModel else { return }
        let handle = ModelHandle(from: currentModel)

        await runtimeActor.unload()
        _loadedModel = nil

        await telemetry.emit(.modelUnloaded(handle: handle, reason: reason))
        log.info("Model unloaded. Reason: \(reason.description, privacy: .public)")
    }

    private static func makeStats(tokens: Int, started: Date) -> RuntimeStats {
        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        return RuntimeStats(
            tokensGenerated: tokens,
            tokensPerSecond: Double(tokens) / elapsed,
            totalDurationMs: Int(elapsed * 1_000)
        )
    }

    /// Validates that the file at `url` is a plausible GGUF model before
    /// handing it to the C++ bridge. Two checks:
    ///
    /// 1. **Size**: a real quantised model is hundreds of MB. Anything under
    ///    1 MB is a dev-mode stub (`"STUB_MODEL"` = 10 bytes).
    /// 2. **Magic**: first 4 bytes must be `GGUF` (0x47 0x47 0x55 0x46).
    ///    An invalid header means the file is corrupt, wrong format, or a
    ///    placeholder.
    ///
    /// Throws `RuntimeError.incompatibleModel` with a user-actionable message
    /// so the error is visible in `RuntimeManager.state` and the Diagnostics view.
    static func validateGGUFFile(at url: URL) throws {
        let fm = FileManager.default

        // --- Size guard ---
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size >= 1_000_000 else {
            throw RuntimeError.incompatibleModel(
                "\(url.lastPathComponent) is too small to be a real model (< 1 MB). " +
                "This is likely a dev-mode stub file. " +
                "Open Settings → Developer Diagnostics and tap 'Reset All Models', " +
                "then download the model for real on this device."
            )
        }

        // --- GGUF magic-bytes guard (0x47 0x47 0x55 0x46 = "GGUF") ---
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw RuntimeError.incompatibleModel(
                "Cannot open model file: \(url.lastPathComponent)"
            )
        }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        guard magic == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw RuntimeError.incompatibleModel(
                "\(url.lastPathComponent) has an invalid GGUF header " +
                "(expected magic 0x47475546). " +
                "The file may be corrupt, a stub, or a non-GGUF format. " +
                "Delete it in Settings → Developer Diagnostics and re-download."
            )
        }
    }
}
