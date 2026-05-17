#if HOMEHUB_LLAMA_RUNTIME
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
    var unloadPolicy: UnloadPolicy = .manual  // Keep model loaded

    // MARK: - Metadata provider

    /// Optional hook injected by `AppContainer` so the llama.cpp runtime
    /// can consult the GGUF metadata cache for:
    ///   - architecture-driven `ChatTemplate` family override
    ///   - native context-length clamp at load time
    /// Mirrors `RuntimeManager.ggufMetadataProvider`. Stays optional so
    /// previews / tests don't need the full graph.
    ///
    /// The provider is invoked **only from `load()`** which runs on the
    /// main actor via `RuntimeManager`. The result is snapshotted into
    /// `_loadedMetadata` so the detached generation Task never reaches
    /// back across an actor boundary.
    var ggufMetadataProvider: (@MainActor (String) -> GGUFModelMetadata?)?

    /// Per-load snapshot of the metadata applicable to `_loadedModel`.
    /// Set by `load()`, cleared by `unload()`. Read by the detached
    /// generation Task without locking — write happens before any
    /// generate() call can borrow the context and the field is
    /// effectively immutable for the lifetime of one load.
    private var _loadedMetadata: GGUFModelMetadata?

    // MARK: - Last error

    /// User-facing snapshot of the last failed generation. Surfaced in
    /// Model Info + DeveloperDiagnostics. Cleared on the next successful
    /// generation. Stored as a single atomic-ish field — only written from
    /// the generation Task, only read from the @MainActor.
    private let errorLock = NSLock()
    private var _lastGenerationError: GenerationFailure?
    var lastGenerationError: GenerationFailure? {
        errorLock.withLock { _lastGenerationError }
    }

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

        // Pre-load memory check — same shape as the MLX path. The 1.25×
        // multiplier covers KV cache + Metal buffers without including
        // the de-quantisation scratch the MLX path needs (llama.cpp
        // mmaps the weights directly, so the overhead is lower).
        if let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
           fileSize > 0 {
            let estimatedFootprint = Int64(Double(fileSize) * 1.25)
            let available = Int64(os_proc_available_memory())
            if available > 0, estimatedFootprint > available {
                log.error("llama.cpp: Pre-load memory check failed — model needs ~\(estimatedFootprint / 1_048_576) MB, only \(available / 1_048_576) MB available")
                throw RuntimeError.outOfMemory
            }
        }

        // GGUF-metadata-aware context clamp. The catalog stores a
        // per-device-tuned `contextLength` (e.g. 2048 on iPhone for safety),
        // and the GGUF header advertises the model's *trained* context
        // (e.g. 32 k for Qwen). We pick the smaller — never widen the
        // catalog hint past what the device can hold, never feed the C++
        // bridge a value past what the model was trained for.
        // load() is invoked from RuntimeManager which is @MainActor;
        // it's safe to call the @MainActor closure here directly.
        let metadata: GGUFModelMetadata? = await MainActor.run {
            ggufMetadataProvider?(model.id)
        }
        _loadedMetadata = metadata
        let effectiveContextLength: Int = {
            if let nativeCtx = metadata?.contextLength, nativeCtx > 0 {
                return min(model.contextLength, nativeCtx)
            }
            return model.contextLength
        }()

        if let arch = metadata?.architecture {
            log.info("llama.cpp load: backend=llama.cpp modelID=\(model.id, privacy: .public) arch=\(arch, privacy: .public) ctx=\(effectiveContextLength) (catalog=\(model.contextLength) metadata=\(metadata?.contextLength ?? -1))")
        } else {
            log.info("llama.cpp load: backend=llama.cpp modelID=\(model.id, privacy: .public) ctx=\(effectiveContextLength) (catalog only; no GGUF metadata available)")
        }

        let started = Date()
        do {
            try await runtimeActor.load(
                model: model,
                path: url.path,
                contextLength: effectiveContextLength
            )
        } catch let runtimeError as RuntimeError {
            throw runtimeError
        } catch {
            throw RuntimeError.underlying(error.localizedDescription)
        }

        _loadedModel = model

        let loadMs = Int(Date().timeIntervalSince(started) * 1_000)
        let handle = ModelHandle(from: model)

        await telemetry.emit(.modelLoaded(handle: handle, durationMs: loadMs))
        log.info("Model loaded: '\(model.displayName, privacy: .public)' in \(loadMs)ms (effective ctx \(effectiveContextLength))")
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
        // Snapshot the per-load metadata cache value once. `load()` writes
        // it under @MainActor before this generate() can be reached, and
        // `unload()` clears it — both happen *outside* this detached Task,
        // so the snapshot is effectively immutable for the lifetime of one
        // generation. We DO NOT call the @MainActor `ggufMetadataProvider`
        // closure from the detached Task — that would be an actor hop on
        // a hot path (and also a Sendable violation).
        let metadata = self._loadedMetadata
        let setError: @Sendable (GenerationFailure?) -> Void = { [weak self] failure in
            guard let self else { return }
            self.errorLock.withLock { self._lastGenerationError = failure }
        }

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

                // Uvolní isGenerating na VŠECH exit paths tohoto Task
                // (normální konec, cancel, throw, CancellationError)
                defer {
                    let localActor = actor
                    Task { await localActor.returnFromGeneration() }
                }

                // Emit generationStarted only after successful borrow so
                // requestID is only surfaced when we know we have a context.
                let loadedModel = await actor.loadedModel
                let handle = loadedModel.map { ModelHandle(from: $0) }

                if let handle {
                    await telemetry.emit(.generationStarted(requestID: requestID, handle: handle))
                }

                // GGUF-metadata-aware template selection. When the header has
                // `general.architecture`, it overrides the catalog `family`
                // string — the model author's identifier wins over our
                // curation. When metadata is absent we fall back to the
                // catalog family exactly like before.
                let modelID = loadedModel?.id ?? "(none)"
                let renderResult = ChatTemplate.render(
                    prompt,
                    family: loadedModel?.family ?? "",
                    metadata: metadata
                )
                let renderedPrompt = renderResult.rendered
                log.debug("llama.cpp generate: backend=llama.cpp modelID=\(modelID, privacy: .public) template=\(String(describing: renderResult.source), privacy: .public)")

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
                        topK: Int32(parameters.topK),
                        minP: Float(parameters.minP),
                        repeatPenalty: Float(parameters.repeatPenalty),
                        repeatPenaltyLastN: Int32(parameters.repeatPenaltyLastN),
                        frequencyPenalty: Float(parameters.frequencyPenalty),
                        presencePenalty: Float(parameters.presencePenalty),
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
                            let now = Date()
                            firstTokenDate = now
                            let ttftMs = Int(now.timeIntervalSince(started) * 1_000)
                            log.debug("TTFT: \(ttftMs)ms (request \(requestID, privacy: .public))")
                            await telemetry.emit(.firstToken(requestID: requestID, latencyMs: ttftMs))
                            // log.debug above already records this through
                            // os.Logger — the extra DEBUG print was duplicate
                            // noise in Xcode console and silenced in Release.
                        }

                        // Per-token autoreleasepool — symmetric with the MLX
                        // runtime patch. `ctx.stream(...)` bridges through
                        // the llama.xcframework, which builds NSString/Data
                        // wrappers around the decoded UTF-8 piece on its way
                        // to Swift. Without an explicit drain those temporaries
                        // sit in the parent pool until the run loop iterates
                        // — across a long reply that's hundreds of objects.
                        // The token mutation is the only ObjC-touching line;
                        // cancellation, telemetry, and continuation yield
                        // stay outside the pool so their semantics are
                        // unchanged (yield does its own work on the continuation
                        // queue, not in this scope).
                        autoreleasepool {
                            tokens += 1
                        }
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
                    // Single-line per-generation summary, aligned with the
                    // MLX backend so log queries can grep both.
                    log.info(
                        "llama.cpp generation: backend=llama.cpp modelID=\(modelID, privacy: .public) tokens=\(stats.tokensGenerated, privacy: .public) durationMs=\(stats.totalDurationMs, privacy: .public) tps=\(String(format: "%.1f", stats.tokensPerSecond), privacy: .public) reason=stop"
                    )
                    await telemetry.emit(.generationFinished(
                        requestID: requestID, stats: stats, reason: .stop
                    ))
                    setError(nil)  // clear any prior failure on success
                    continuation.yield(.finished(reason: .stop, stats: stats))
                    continuation.finish()

                } catch is CancellationError {
                    setError(GenerationFailure.classify(
                        CancellationError(), modelID: modelID, backend: "llama.cpp"
                    ))
                    continuation.finish()
                } catch {
                    let failure = GenerationFailure.classify(
                        error, modelID: modelID, backend: "llama.cpp"
                    )
                    setError(failure)
                    log.error("llama.cpp generation: backend=llama.cpp modelID=\(modelID, privacy: .public) failed kind=\(String(describing: failure.kind), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
        _loadedMetadata = nil
        errorLock.withLock { _lastGenerationError = nil }

        await telemetry.emit(.modelUnloaded(handle: handle, reason: reason))
        log.info("llama.cpp runtime unload: backend=llama.cpp modelID=\(currentModel.id, privacy: .public) reason=\(reason.description, privacy: .public)")
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

#endif // HOMEHUB_LLAMA_RUNTIME
