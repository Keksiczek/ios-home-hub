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

// Throttle helper for the download-progress diagnostic log. Same sequential-
// access invariant as `PhaseSignal` — the MLX downloader calls the progress
// adapter from a single task at a time, so the @unchecked is safe.
private final class ProgressLogThrottle: @unchecked Sendable {
    var lastLoggedFraction: Double = -1
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
    /// When `true`, a soft memory-pressure event arrived during a live
    /// generation. The generation epilogue (see `generate()`'s defer)
    /// drops the `ChatSession` so the next turn observes a fresh start
    /// and the deferred trim actually frees the scratch.
    private var pendingSessionTrim: Bool = false
    private let sessionLock = NSLock()

    private struct ActiveSession: @unchecked Sendable {
        /// The model the session was constructed under. The reuse check
        /// also gates on this — same conversationID but different model
        /// ID must invalidate the KV cache, since the cached prefix is
        /// tokenised against a different vocab.
        let modelID: String
        let conversationID: UUID
        /// Stable portion of the system prompt — persona, profile, tools,
        /// language policy. Everything that doesn't churn turn-by-turn.
        /// The cache reuse check compares this only; the volatile half
        /// (date/time, conversation recall, semantic facts) is injected
        /// into the current user turn instead, so the cached prefix
        /// stays valid across turns where only volatile context changed.
        ///
        /// Before this split, `existing.systemPrompt != prompt.systemPrompt`
        /// compared the concatenated whole — and because the volatile
        /// block carries the current minute/second, the cache was
        /// discarded on practically every turn. End result: full
        /// re-prefill of system + history on every send, which on a
        /// 1500-token system prompt costs 200-500 ms before the first
        /// token streams.
        let stableSystemPrompt: String
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

    /// Rolling per-model sample history (most-recent first) for
    /// percentile reporting. Capped at `tpsSampleCap` per model so the
    /// memory footprint stays bounded over a long session even on
    /// heavy power users. p50 catches typical performance; p95 surfaces
    /// the worst-case tail that mean averaging hides — a model with
    /// mean 30 t/s and p95-of-2 t/s is functionally unusable even
    /// though the mean looks fine. Protected by `sessionLock`.
    private var tpsSamples: [String: [Double]] = [:]
    private static let tpsSampleCap = 128

    /// Rolling per-model first-token-latency samples (ms). Tracks the
    /// gap between calling `streamResponse` and the first token
    /// arriving — i.e. the prefill cost users actually feel. Same
    /// 128-sample cap as throughput. Protected by `sessionLock`.
    private var ttftSamplesMs: [String: [Int]] = [:]

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

    /// Snapshot of the throughput distribution. Returns `(p50, p95)` of
    /// the rolling per-model sample buffer along with the sample count.
    /// `nil` when no samples are available yet. p50/p95 chosen over
    /// p99 because the buffer is capped at 128 (one p99 sample = noise).
    func throughputPercentiles(for modelID: String) -> (p50: Double, p95: Double, samples: Int)? {
        sessionLock.withLock {
            guard let samples = tpsSamples[modelID], !samples.isEmpty else { return nil }
            let sorted = samples.sorted()
            let p50 = percentile(sorted, fraction: 0.5)
            let p95 = percentile(sorted, fraction: 0.95)
            return (p50, p95, sorted.count)
        }
    }

    /// Snapshot of the first-token-latency distribution for `modelID`,
    /// in milliseconds. Returns `(p50, p95, sampleCount)` or `nil` when
    /// no generations have been observed yet. TTFT is the dominant
    /// component of user-perceived "is it stuck?" — surfacing p95
    /// alongside p50 lets diagnostics flag a model whose typical
    /// prefill is fast but tail cases are pathological.
    func firstTokenLatencyPercentiles(for modelID: String) -> (p50Ms: Int, p95Ms: Int, samples: Int)? {
        sessionLock.withLock {
            guard let samples = ttftSamplesMs[modelID], !samples.isEmpty else { return nil }
            let sorted = samples.sorted().map(Double.init)
            let p50 = Int(percentile(sorted, fraction: 0.5).rounded())
            let p95 = Int(percentile(sorted, fraction: 0.95).rounded())
            return (p50, p95, sorted.count)
        }
    }

    /// Nearest-rank percentile. Input MUST be sorted ascending. For
    /// fraction 0.95 with 10 samples returns sorted[9] (the 10th value);
    /// for fraction 0.50 with 10 samples returns sorted[5] (the upper
    /// of the two middle values — matches NumPy `nearest` semantics).
    nonisolated static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = max(0.0, min(1.0, fraction))
        let rank = Int((clamped * Double(sorted.count - 1)).rounded())
        return sorted[rank]
    }

    /// Instance-visible bridge — keeps the call-site short while
    /// preserving the pure static algorithm above for testability.
    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        Self.percentile(sorted, fraction: fraction)
    }

    /// The baseline GPU cache limit applied at init time. Stored so the
    /// adaptive resize on memory pressure (`adjustGPUCacheLimit(...)`) can
    /// restore the headroom when pressure clears. `0` until first init.
    private var baselineCacheLimitBytes: Int = 0

    /// Tier-based multipliers applied to the baseline GPU cache. Picked so
    /// the cache is reactive (`.tight 0.25x` is small enough to actually
    /// matter under jetsam pressure) without churning between values that
    /// MLX's internal buffer pool would have to drop and recreate
    /// frequently. Calling `MLX.Memory.cacheLimit = X` itself is cheap;
    /// the real cost is the eviction wave it triggers.
    fileprivate enum CachePressureTier {
        case normal, soft, hard
        var multiplier: Double {
            switch self {
            case .normal: return 1.0
            case .soft:   return 0.6
            case .hard:   return 0.25
            }
        }
    }

    /// Last tier that was actually applied. Used to no-op redundant
    /// `adjustGPUCacheLimit(...)` calls — the assignment is cheap but the
    /// log line is noisy and the eviction can churn buffer pools when
    /// hammered every 5 s during sustained pressure.
    private var currentCacheTier: CachePressureTier = .normal

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
        self.baselineCacheLimitBytes = Int(cacheLimitBytes)
        MLX.Memory.cacheLimit = self.baselineCacheLimitBytes

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

    /// Adjust the MLX GPU buffer-pool ceiling based on current pressure
    /// tier. Tracks `baselineCacheLimitBytes` so pressure scaling stays
    /// consistent across the device-tier × hardware-budget product.
    ///
    /// Called from `handleMemoryPressure` (hard tier — pressure is real
    /// enough that we shrink to 25%) and `trimMemoryCaches` (soft tier
    /// — 60%, preserves enough pool to keep prefill fast). The
    /// `restoreCacheLimit()` call on the next clean generation finish
    /// returns the pool to baseline so a quiet device doesn't pay
    /// permanently for a transient L1 event.
    fileprivate func adjustGPUCacheLimit(to tier: CachePressureTier) {
        guard baselineCacheLimitBytes > 0 else { return }
        guard tier != currentCacheTier else { return }
        let target = Int(Double(baselineCacheLimitBytes) * tier.multiplier)
        MLX.Memory.cacheLimit = target
        currentCacheTier = tier
        log.info("MLX: GPU cache limit -> \(target / 1024 / 1024, privacy: .public) MB (tier=\(String(describing: tier), privacy: .public))")
    }

    /// Convenience used by the generation epilogue — only restore to
    /// `.normal` if we're actually below baseline. Avoids logging on
    /// every successful turn.
    fileprivate func restoreCacheLimitIfShrunk() {
        if currentCacheTier != .normal {
            adjustGPUCacheLimit(to: .normal)
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

        // Pre-flight: if the model is already on disk, fail fast with a
        // typed, user-readable error rather than letting the MLX loader
        // throw an opaque tokeniser / safetensors message. We only
        // pre-flight when the cache directory exists at all — first-load
        // (cold cache) is handled by the loader's own progress flow.
        let preflight = LocalModelService.inspectMLXCache(repoId: repoId)
        if preflight.directoryExists, preflight.state != .ready {
            let reason = preflight.failureReason ?? "Model directory is incomplete."
            self.log.error("MLX: Pre-flight failed for '\(repoId, privacy: .public)' — \(reason, privacy: .public)")
            if !preflight.missingItems.isEmpty {
                throw RuntimeError.missingFiles(
                    modelName: model.displayName,
                    missing: preflight.missingItems
                )
            }
            throw RuntimeError.invalidModelDirectory(
                modelName: model.displayName,
                detail: reason
            )
        }

        // Pre-load memory check. This is a LAST-RESORT guard against the
        // hopeless case, NOT the primary feasibility gate — `RuntimeManager`
        // already runs `evaluateFeasibility` and the user explicitly opts
        // in to risky loads ("Load anyway"). So this only hard-fails when
        // even a generously-paged load can't possibly work, and otherwise
        // lets the attempt proceed (the memory-pressure handler + jetsam
        // are the backstop).
        //
        // Why the old `weights × 1.35 > available` gate was wrong:
        //   * MLX memory-maps the weight files — read-only weight pages are
        //     file-backed (clean) and can be evicted/reloaded by the VM, so
        //     they don't count fully against `os_proc_available_memory()`'s
        //     dirty-memory budget. Comparing raw file size to that budget
        //     refuses models that actually run fine.
        //   * Architectures like Gemma 3n (Per-Layer Embeddings / MatFormer)
        //     have a resident footprint well below their on-disk size, so a
        //     flat 1.35× multiplier over-estimates badly and blocked models
        //     other apps load without issue.
        //
        // We now only refuse when the raw weights exceed ~2× the available
        // budget — past that, paging thrashes hopelessly regardless of
        // architecture. Everything below that is allowed to try.
        if preflight.totalWeightsBytes > 0 {
            let raw = preflight.totalWeightsBytes
            let available = Int64(os_proc_available_memory())
            let mbRaw = raw / 1_048_576
            let mbAvailable = available / 1_048_576
            if available > 0, raw > available * 2 {
                self.log.error("MLX: Pre-load memory check failed — weights ~\(mbRaw) MB exceed 2× available \(mbAvailable) MB; refusing")
                throw RuntimeError.outOfMemory
            }
            if available > 0, raw > available {
                self.log.notice("MLX: tight memory — weights ~\(mbRaw) MB vs \(mbAvailable) MB available; attempting load anyway (mmap-backed weights may still fit)")
            } else {
                self.log.info("MLX: Pre-load memory OK — weights \(mbRaw) MB, available \(mbAvailable) MB")
            }
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
        //
        // **Observability**: diagnostic counter so the Console log shows
        // whether the upstream `HubApiDownloader` actually surfaces
        // intermediate progress or only fires once at 100 %. If the user
        // reports "stuck at 'Preparing…' with no progress bar", this
        // line lets us tell whether the bug is in the callback wiring
        // (our side) or the MLX framework's reporting cadence (their
        // side). One log per ~10 % step keeps the noise bounded for the
        // common case where progress reports continuously.
        let phaseSignal = PhaseSignal()
        let logThrottle = ProgressLogThrottle()
        let logRef = self.log
        let progressAdapter: @Sendable (Progress) -> Void = { [logRef, repoId, logThrottle] progress in
            let fraction = max(0, min(1, progress.fractionCompleted))
            // Throttled diagnostic log at every 10 % step so the user can
            // confirm in Console that intermediate progress IS arriving.
            // First fire (fraction < 0.1) always logs so the absence of
            // any log = "framework never called us during this download".
            if fraction - logThrottle.lastLoggedFraction >= 0.1 || logThrottle.lastLoggedFraction < 0 {
                logThrottle.lastLoggedFraction = fraction
                logRef.debug("MLX: download progress for '\(repoId, privacy: .public)' → \(Int(fraction * 100), privacy: .public)%")
            }
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
            pendingSessionTrim = false
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

                // Bug fix: previous code dropped topK / minP /
                // repeatPenalty with a warning ("not supported by
                // current GenerateParameters"). The current
                // mlx-swift-lm GenerateParameters DOES support all of
                // these knobs — the warning was stale. With only
                // temperature + topP wired through, Gemma 3n and
                // similar small models had no repetition pressure
                // and drifted into other languages (Czech replies
                // bleeding Russian / Spanish tokens — classic
                // small-model symptom of missing repetition penalty
                // + over-permissive sampling).
                //
                // `repetitionPenalty` is an Optional<Float>: a value
                // of exactly 1.0 means "no penalty" and we pass nil
                // so the sampler short-circuits the bookkeeping.
                // `repetitionContextSize` mirrors the legacy llama.cpp
                // `repeat_last_n` setting.
                let repetitionPenalty: Float? = parameters.repeatPenalty > 1.0
                    ? Float(parameters.repeatPenalty)
                    : nil

                let generateParameters = GenerateParameters(
                    maxTokens: parameters.maxTokens,
                    temperature: Float(parameters.temperature),
                    topP: Float(parameters.topP),
                    topK: parameters.topK,
                    minP: Float(parameters.minP),
                    repetitionPenalty: repetitionPenalty,
                    repetitionContextSize: max(0, parameters.repeatPenaltyLastN)
                )

                let start = Date()
                var tokensGenerated = 0
                var currentText = ""
                var hitMaxTokens = false
                // First-token latency (prefill cost). Recorded the first
                // time a piece actually arrives from the stream — the
                // gap between this and `start` is dominated by prompt
                // tokenisation + KV-cache prefill, the single biggest
                // user-perceived "is the app working?" wait. Surfaced
                // through `firstTokenLatency(for:)` for diagnostics.
                var firstTokenAt: Date?

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
                            } else if existing.stableSystemPrompt != prompt.stableSystemPrompt {
                                // Stable-only comparison: volatile churn
                                // (time, recall, facts) lives in the
                                // current user turn instead of the
                                // ChatSession instructions, so it doesn't
                                // invalidate the cached prefix.
                                discardReason = "different stable systemPrompt"
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
                        // Construct the ChatSession with the STABLE
                        // system prompt only. The volatile half is
                        // injected into the current user turn below
                        // (see `lastTurn` / `userTurnWithVolatile`),
                        // so it reaches the model on every turn
                        // without invalidating the cached prefix.
                        let instructions = prompt.stableSystemPrompt.isEmpty
                            ? (prompt.systemPrompt.isEmpty ? nil : prompt.systemPrompt)
                            : prompt.stableSystemPrompt
                        let newSession = ChatSession(
                            nativeContainer,
                            instructions: instructions,
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
                                stableSystemPrompt: prompt.stableSystemPrompt,
                                messages: canonicalHistory,
                                session: newSession
                            )
                        }
                        return newSession
                    }

                    let lastTurn = MLXChatInput.lastTurn(from: prompt)

                    // Volatile context is prepended to the current
                    // user turn so the model sees up-to-date date /
                    // time / recall / facts on every send while the
                    // cached prefix (stable instructions + earlier
                    // history) stays valid. Delimited so the model
                    // can distinguish the contextual preamble from
                    // the actual question.
                    //
                    // Only applied when the turn is from the user —
                    // tool-followup turns roleplay an assistant
                    // message containing the action invocation and
                    // we don't want to graft system context onto
                    // those.
                    let injectedContent: String
                    if !prompt.volatileSystemPrompt.isEmpty, lastTurn.role == .user {
                        injectedContent = """
                            <context>
                            \(prompt.volatileSystemPrompt)
                            </context>

                            \(lastTurn.content)
                            """
                    } else {
                        injectedContent = lastTurn.content
                    }

                    session.generateParameters = generateParameters

                    // Apply caller-supplied seed if set. Production
                    // turns leave `parameters.seed == nil` and the
                    // global RNG advances freely; debug / reproducer
                    // turns can pin a value via
                    // `RuntimeParameters.seed` to make sampling
                    // bit-identical across runs. `MLXRandom.seed`
                    // mutates global state on the MLX side — fine
                    // because the actor's session lock serialises
                    // generations.
                    if let seed = parameters.seed {
                        MLXRandom.seed(seed)
                    }

                    let responseStream = session.streamResponse(
                        to: injectedContent,
                        role: lastTurn.role,
                        images: [],
                        videos: []
                    )

                    var buffer = ""
                    var lastYieldTime = Date()

                    // Generation watchdog — fires non-fatal warnings at
                    // 30 s / 60 s / 120 s of token silence so the UI can
                    // surface "model is taking longer than usual" without
                    // disturbing the actual decode. Shared via NSLock
                    // (Sendable-safe class wrapper) because the watchdog
                    // task runs concurrently with the for-await loop.
                    let watchdog = GenerationWatchdog(
                        log: self.log,
                        conversationID: conversationID,
                        continuation: continuation
                    )
                    watchdog.start()

                    for try await piece in responseStream {
                        if Task.isCancelled { break }
                        watchdog.recordToken()
                        if firstTokenAt == nil { firstTokenAt = Date() }

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

                    watchdog.stop()

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
                    let watchdog = GenerationWatchdog(
                        log: self.log,
                        conversationID: conversationID,
                        continuation: continuation
                    )
                    watchdog.start()
                    defer { watchdog.stop() }
                    let fallbackResult: (Int, String, Bool) = try await container.perform { [watchdog] context in
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
                                watchdog.recordToken()
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
                var honourPendingTrim = false
                self.sessionLock.withLock {
                    self.activeTask = nil
                    self.activeGenerationID = nil
                    self.isGenerating = false
                    self._lastGenerationError = nil
                    if self.pendingSessionTrim {
                        self.activeSession = nil
                        self.pendingSessionTrim = false
                        honourPendingTrim = true
                    }
                    if tokensGenerated > 0 {
                        let prev = self.tpsAverage[modelID] ?? (mean: 0, n: 0)
                        let n = prev.n + 1
                        let mean = prev.mean + (tps - prev.mean) / Double(n)
                        self.tpsAverage[modelID] = (mean: mean, n: n)

                        // Maintain ring-buffer-ish sample list for
                        // percentile reporting. Append + trim from the
                        // FRONT so newest samples dominate the
                        // distribution after the cap is reached —
                        // matches user intuition of "recent performance".
                        var samples = self.tpsSamples[modelID] ?? []
                        samples.append(tps)
                        if samples.count > Self.tpsSampleCap {
                            samples.removeFirst(samples.count - Self.tpsSampleCap)
                        }
                        self.tpsSamples[modelID] = samples

                        // First-token latency sample. Captured only when
                        // we actually observed a first token (the
                        // optional bind in `firstTokenAt` skips cancelled-
                        // before-decode generations whose latency number
                        // would be the cancel-detection time, not the
                        // prefill cost).
                        if let firstTokenAt {
                            let ttftMs = Int(firstTokenAt.timeIntervalSince(start) * 1000)
                            var ttftBuf = self.ttftSamplesMs[modelID] ?? []
                            ttftBuf.append(ttftMs)
                            if ttftBuf.count > Self.tpsSampleCap {
                                ttftBuf.removeFirst(ttftBuf.count - Self.tpsSampleCap)
                            }
                            self.ttftSamplesMs[modelID] = ttftBuf
                        }
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

                if honourPendingTrim {
                    self.log.info("MLX: pendingSessionTrim honoured — ChatSession dropped after generation finish")
                }

                // If we shrunk the GPU buffer pool under a recent pressure
                // event, restore it now that a generation just completed
                // cleanly. The next turn will see the full baseline pool
                // available for prefill — keeps the "pressure was
                // transient" common case from paying a permanent slow tax.
                self.restoreCacheLimitIfShrunk()

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
                    if self.pendingSessionTrim {
                        self.activeSession = nil
                        self.pendingSessionTrim = false
                    }
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
        // Shrink the GPU buffer pool to its hard-tier floor before the
        // unload tears down the container. If the user keeps the app in
        // foreground and a fresh load comes in next, this leaves more
        // room for the new weights to map. The next clean generation
        // finish restores baseline.
        adjustGPUCacheLimit(to: .hard)
        await unload()
    }

    /// Soft tier of memory pressure: drop the prefix-reuse `ChatSession`
    /// and stale generation-failure crumb, **keep** the model container
    /// (weights stay resident). Frees the per-conversation KV-cache
    /// scratch (~10–80 MB on small models, scales with context) and is
    /// essentially free — the next turn reconstructs the session from
    /// the persisted history. Cheap enough to call on every L1 warning.
    ///
    /// **Safety during streaming**: if `isGenerating` is true the active
    /// `ChatSession` is being read by the generator task; dropping it
    /// out from under that task is harmless for ARC (the task already
    /// holds a strong ref) but lets the next turn observe `nil` and
    /// rebuild — wasting the prefix-reuse benefit for the in-flight
    /// reply. We instead set a deferred flag and let the generator's
    /// `finally` path do the drop. Keeps the contract "trim is cheap
    /// and never interrupts a streaming reply".
    func trimMemoryCaches() async {
        let (hadSession, deferred): (Bool, Bool) = sessionLock.withLock {
            if isGenerating {
                pendingSessionTrim = activeSession != nil
                return (false, pendingSessionTrim)
            }
            let had = activeSession != nil
            activeSession = nil
            _lastGenerationError = nil
            return (had, false)
        }
        // Shrink the buffer pool to the soft-tier floor. 60% of baseline
        // keeps prefill responsive (the pool can satisfy most
        // intermediate-tensor allocations without re-mapping) while
        // releasing the bulk of what the user got asked to evacuate.
        adjustGPUCacheLimit(to: .soft)
        if hadSession {
            self.log.info("MLX: trimMemoryCaches — dropped ChatSession (KV-cache scratch)")
        } else if deferred {
            self.log.info("MLX: trimMemoryCaches — deferred (generation in progress); will drop on finish")
        }
    }

    /// Snapshot the busy flag under the lock so the pressure policy can
    /// decide whether to debounce the hard unload past the current turn.
    var isCurrentlyGenerating: Bool {
        sessionLock.withLock { isGenerating }
    }

    /// Real BPE token count via the active MLX tokenizer. Snapshots the
    /// container under the session lock (so a concurrent unload can't
    /// invalidate it mid-call), then enters the actor via `perform`
    /// to access `context.tokenizer.encode(text:)`. Returns `nil` when
    /// no model is loaded, a generation is in flight (would race the
    /// container access), or the tokenizer throws on the input.
    ///
    /// **Why not always-on.** The encoding step is ~1ms for short
    /// prompts but climbs to 10-20ms for multi-KB system prompts. We
    /// keep the per-streaming-token watchdog on the cheap heuristic
    /// and only reach for the real tokenizer when accuracy matters
    /// (budget calibration, diagnostics).
    func realTokenCount(of text: String) async -> Int? {
        guard !text.isEmpty else { return 0 }
        let snapshot = sessionLock.withLock { container }
        guard let container = snapshot else { return nil }
        // `container.perform { ... }` propagates `rethrows`, and
        // `ctx.tokenizer.encode(text:)` is non-throwing — keep the
        // call non-throwing too so the compiler doesn't flag the
        // wrapping `do/catch` as dead. If the upstream encode ever
        // gains throwing semantics, re-add the catch.
        return await container.perform { ctx in
            ctx.tokenizer.encode(text: text).count
        }
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
