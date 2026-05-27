import Foundation
import SwiftUI
import os

// Links to the Darwin os/proc.h symbol. Available from iOS 14 / macOS 11.
// The app targets iOS 17+, so no availability guard is needed.
// size_t maps to UInt on 64-bit platforms.
@_silgen_name("os_proc_available_memory")
private func _os_proc_available_memory() -> UInt

/// Owns the currently active `LocalLLMRuntime` and exposes its state
/// to the UI. This is the *only* place in the app that knows about
/// model loading and unloading; everyone else talks to it.
///
/// ## Active-model reference audit
///
/// `activeModel` (the canonical source of truth) is stored **only here**.
/// All other sites that read it do so via this manager, not via a
/// separate retained copy:
///
/// - `AppContainer.runtimeManager.activeModel` — read-only checks in
///   bootstrap and lifecycle handlers (AppContainer.swift).
/// - `ConversationService.runtime.activeModel` — `runtime` is a
///   `RuntimeManager`; `activeModel` is read to attach the model ID to
///   conversation messages.
/// - `ModelDownloadService.runtime.activeModel` — read to decide whether
///   to auto-load after a successful download.
/// - UI views (`ModelsView`, `ChatDetailView`, …) observe `activeModel`
///   via `@Published` on this class; they hold no independent copies.
///
/// When `unload()` or `_performUnload()` sets `activeModel = nil`, all of
/// the above immediately see the change. There is no secondary owner to clear.
///
/// ## Load / unload mutual exclusion
///
/// Every public state-mutating method acquires `operationTask` before
/// proceeding (see `operationTask` documentation below). This prevents:
/// - rapid "Load" button taps from launching concurrent loads
/// - a new load starting while an unload is still in progress
/// - an unload racing with the unload-before-load phase of `_performLoad`
@MainActor
final class RuntimeManager: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        /// Emitted briefly while the current model is being released before
        /// a new load, or during an explicit `unload()` call. Indicates that
        /// GPU/RAM buffers are being freed; a new `load()` will wait for this
        /// to complete rather than interleaving with the deallocation.
        case unloading
        case loading(modelID: String)
        case ready(modelID: String)
        case failed(modelID: String?, reason: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var activeModel: LocalModel?
    /// Non-nil while an MLX model is downloading or initializing.
    /// Set to `nil` immediately when loading completes, fails, or is cancelled.
    @Published private(set) var mlxLoadProgress: MLXLoadProgress?

    // MARK: - Runtime

    let runtime: any LocalLLMRuntime

    // MARK: - Memory gate configuration

    /// Safety factor applied to `model.sizeBytes` in the memory preflight,
    /// for the **balanced** profile. Retained as a constant for code that
    /// reads it directly (e.g. DeveloperDiagnostics defaults). Live callers
    /// should prefer `memorySafetyFactor(for:)` so the user's chosen
    /// `PerformanceProfile` is respected.
    static let memorySafetyFactor: Double = 1.5

    /// Profile → safety-factor mapping. Conservative trades a chance of
    /// being told "no" against a chance of getting OOM-killed mid-load;
    /// aggressive does the opposite. `nonisolated` so `evaluateFeasibility`
    /// can call it from off-actor code paths.
    nonisolated static func memorySafetyFactor(for profile: PerformanceProfile) -> Double {
        switch profile {
        case .conservative: return 1.8
        case .balanced:     return 1.5
        case .aggressive:   return 1.3
        }
    }

    // MARK: - Concurrency handles

    /// Inner weight-loading task (expensive, cooperative-cancellable).
    ///
    /// Created as a `Task.detached(priority: .userInitiated)` inside
    /// `_performLoad` so the heavy metal pipeline compilation runs off the
    /// `@MainActor` executor. Stored so pressure/thermal handlers can cancel
    /// it quickly before issuing an unload.
    private var mlxLoadTask: Task<Void, Error>?

    /// Single serialisation gate for ALL state-changing operations.
    ///
    /// Every public method that mutates `state` or `activeModel`:
    ///   1. Optionally cancels `mlxLoadTask` to interrupt an in-flight load.
    ///   2. Waits for the current `operationTask` (a `while` loop handles the
    ///      case where multiple callers queue up).
    ///   3. Creates its own `Task<Void, Never>`, assigns it to `operationTask`.
    ///   4. Awaits that task.
    ///   5. Clears `operationTask` if it's still the same instance.
    ///
    /// Mutual exclusion guarantee: because `RuntimeManager` is `@MainActor`,
    /// no preemption occurs between steps 2 and 3 — nothing can sneak into
    /// the slot between checking that `operationTask == nil` and assigning the
    /// new task.
    private var operationTask: Task<Void, Never>?

    // MARK: - Metadata provider

    /// Optional hook used to look up cached GGUF metadata for a model when
    /// `_performLoad` logs the template source and effective context.
    /// Wired by `AppContainer` to `modelCatalogService.metadata(for:)`.
    /// Stays optional so previews / unit tests don't need the full graph.
    /// `@MainActor`-isolated because the only caller runs on the main actor
    /// (the surrounding class is `@MainActor`) and the catalog service is
    /// itself `@MainActor`.
    var ggufMetadataProvider: (@MainActor (String) -> GGUFModelMetadata?)?

    /// Callback fired when a load attempt fails because the on-disk
    /// cache is broken (`RuntimeError.missingFiles` or
    /// `.invalidModelDirectory`). Lets `AppContainer` flip the
    /// catalog entry back to `.notInstalled` AND wipe the broken
    /// cache so the user's next view shows a clean Download CTA
    /// instead of a stale Load button on a model whose disk
    /// representation is structurally unusable.
    ///
    /// The callback is invoked even when the runtime state was set
    /// to `.failed(...)` — the two paths are complementary:
    ///   * `state = .failed(...)`        → UI surfaces the load error.
    ///   * `onBrokenCacheDetected(...)`  → catalog + disk are reset so
    ///                                     the next interaction starts
    ///                                     from a known-good state.
    /// Both fire from the same catch branch; the closure is fire-
    /// and-forget so a slow catalog mutation doesn't block the load
    /// error from surfacing in the UI.
    var onBrokenCacheDetected: (@MainActor (LocalModel, String) -> Void)?

    /// Active performance profile — drives `memorySafetyFactor` selection
    /// inside `memoryCheck(for:)`. Changing this only affects *future*
    /// load calls; an already-loaded model keeps the factor it loaded
    /// under until the next `load()` / `unload()` cycle.
    var performanceProfile: PerformanceProfile = .balanced

    // MARK: - Telemetry

    /// Structured telemetry channel for the active runtime.
    var telemetry: RuntimeTelemetry { runtime.telemetry }

    /// Last user-facing generation failure, surfaced by the active
    /// runtime. `nil` while no generation has failed since the most
    /// recent successful one. Backend-agnostic — both MLX and llama.cpp
    /// store the value through this protocol so views never branch on
    /// the concrete runtime type. See `LocalLLMRuntime+lastError`.
    var lastGenerationError: GenerationFailure? {
        runtime.lastGenerationError
    }

    /// Rolling mean tokens/sec for `modelID`, or `nil` if the active
    /// runtime hasn't generated for that model yet. Used by
    /// `DeveloperDiagnostics`. Returns `nil` for runtimes that don't
    /// track per-model throughput (e.g. the mock runtime in previews).
    func averageThroughput(for modelID: String) -> (tps: Double, samples: Int)? {
        runtime.averageThroughput(for: modelID)
    }

    /// Throughput distribution (p50, p95) for `modelID`. Surfaces the
    /// tail latency that `averageThroughput` hides. Returns `nil` for
    /// runtimes that don't track per-sample history (mock, llama.cpp).
    func throughputPercentiles(for modelID: String) -> (p50: Double, p95: Double, samples: Int)? {
        runtime.throughputPercentiles(for: modelID)
    }

    /// First-token latency distribution (median + p95, ms) for `modelID`.
    /// Independent signal from throughput — captures the prefill cost
    /// that determines user-perceived "is it stuck" wait. `nil` for
    /// runtimes that don't track this.
    func firstTokenLatencyPercentiles(for modelID: String) -> (p50Ms: Int, p95Ms: Int, samples: Int)? {
        runtime.firstTokenLatencyPercentiles(for: modelID)
    }

    private let log = Logger(subsystem: "com.homehub.app", category: "RuntimeManager")

    // MARK: - Init

    init(runtime: any LocalLLMRuntime) {
        self.runtime = runtime
    }

    // MARK: - Load

    func load(_ model: LocalModel) async {
        // Fast-path idempotence: if this model is already loading or ready,
        // return immediately without acquiring the operation slot.
        switch state {
        case .loading(let id) where id == model.id: return
        case .ready(let id)   where id == model.id: return
        default: break
        }

        // Wait for any in-flight operation (load, unload, or pressure handler
        // that set operationTask). The loop re-checks idempotence on each
        // wakeup because a queued load for the same model may have finished.
        while let op = operationTask {
            await op.value
            switch state {
            case .loading(let id) where id == model.id: return
            case .ready(let id)   where id == model.id: return
            default: break
            }
        }

        let task = Task<Void, Never> { [weak self] in await self?._performLoad(model) }
        operationTask = task
        await task.value
        if operationTask == task { operationTask = nil }
    }

    private func _performLoad(_ model: LocalModel) async {
        log.info("Runtime: Loading '\(model.id, privacy: .public)'")

        // Phase 1: Release the current model so ARC can reclaim GPU buffers
        // before the new load starts. Without this, Metal briefly holds weights
        // for both models simultaneously, doubling peak Unified Memory and
        // triggering EXC_RESOURCE on constrained devices.
        activeModel = nil
        state = .unloading
        await runtime.unload()

        // Phase 2: Yield for ARC / Metal lazy-deallocation.
        await Task.yield()

        state = .loading(modelID: model.id)
        mlxLoadProgress = nil

        // Per-load decision log — one line per load() call. Logs the
        // template source (GGUF metadata vs built-in family fallback) and
        // the effective context length so multi-turn issues can be
        // correlated to template + context without reattaching Xcode.
        logLoadDecision(for: model)

        // Memory preflight — abort before allocating anything.
        //
        // Run the oracle off the main actor: `os_proc_available_memory()`
        // is a fast sysctl call, but doing it via `Task.detached` is the
        // documented way to keep heavier future variants (e.g.
        // `mach_host_statistics` fallback) off the UI watchdog, and it
        // keeps the contract honest — the user explicitly asked for the
        // preflight to run off main thread.
        let currentProfile = performanceProfile
        let modelForOracle = model
        let verdict: LoadFeasibility? = await Task.detached(priority: .userInitiated) {
            Self.evaluateFeasibility(for: modelForOracle, profile: currentProfile)
        }.value
        lastFeasibilityVerdict = verdict

        if let verdict {
            let fmt = ByteCountFormatter()
            fmt.allowedUnits = [.useMB, .useGB]
            fmt.countStyle = .file
            switch verdict {
            case .cannotLoad(let requiredBytes, let availableBytes):
                let needBytes = fmt.string(fromByteCount: requiredBytes)
                let haveBytes = fmt.string(fromByteCount: availableBytes)
                let hint: String
                switch currentProfile {
                case .aggressive, .balanced:
                    hint = "Zkuste menší model nebo přepněte profil výkonu na Konzervativní v Nastavení."
                case .conservative:
                    hint = "Zkuste menší model — tento se na toto zařízení nevejde ani s konzervativní rezervou."
                }
                log.warning("Runtime: Memory oracle CANNOT_LOAD '\(model.id, privacy: .public)' — need \(requiredBytes) B raw, have \(availableBytes) B (profile=\(currentProfile.rawValue, privacy: .public))")
                state = .failed(
                    modelID: model.id,
                    reason: "Model se na toto zařízení v aktuálním stavu nevejde: potřebuje ≈\(needBytes), volných je jen \(haveBytes). \(hint)"
                )
                return
            case .risky(let requiredBytes, let availableBytes):
                // Load proceeds — the user opted in. The verdict stays
                // on `lastFeasibilityVerdict` so DeveloperDiagnostics +
                // any future "tight fit" UI surface can read it.
                log.notice("Runtime: Memory oracle RISKY '\(model.id, privacy: .public)' — safe-margin requires \(requiredBytes) B, have \(availableBytes) B — proceeding under user opt-in")
            case .safe(let headroomBytes):
                log.info("Runtime: Memory oracle SAFE '\(model.id, privacy: .public)' — headroom \(headroomBytes) B (profile=\(currentProfile.rawValue, privacy: .public))")
            }
        }

        // Phase 3: Load off @MainActor. Task.detached moves Metal pipeline
        // compilation (10–60 s on older hardware) off the UI watchdog's executor.
        //
        // **Stall watchdog.** The inner load can hang on a flaky TLS
        // handshake, a Hub redirect loop, or — observed in production —
        // a Metal pipeline compile that doesn't surface progress events
        // for minutes. Without a deadline the UI sits on the spinner
        // until the user kills the app. We track the last progress
        // tick and arm a sibling task that cancels the load if no
        // tick arrives within `loadStallTimeoutSeconds`. The deadline
        // *resets* on every progress event, so a slow-but-progressing
        // download is fine; only a true stall trips it.
        lastLoadProgressAt = Date()
        let modelID = model.id
        // Progress events fire from the loader thread at high frequency
        // (one per chunk on Hub downloads — easily 20+/s on Wi-Fi).
        // Each one used to schedule a fresh `Task @MainActor` to update
        // `mlxLoadProgress`, fragmenting the main actor with no UX
        // benefit (the progress bar can't render faster than the
        // display refresh anyway). Throttle to ~10 Hz while letting
        // **phase transitions** through immediately — going from
        // `.downloading` to `.preparing` is the one moment the UI
        // *must* update or the user sees a stuck progress bar.
        let throttle = LoadProgressThrottle()
        let loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            try await self.runtime.loadWithProgress(model: model) { [weak self] phase in
                guard throttle.shouldEmit(phase: phase) else { return }
                Task { @MainActor [weak self] in
                    self?.mlxLoadProgress = MLXLoadProgress(modelID: modelID, phase: phase)
                    self?.lastLoadProgressAt = Date()
                    self?.currentLoadPhase = phase
                }
            }
        }
        mlxLoadTask = loadTask

        // Sibling watchdog. Lives only as long as the load itself —
        // when the load finishes (any path), we cancel the watchdog so
        // it doesn't tick into the next load. The watchdog is the only
        // task that touches `loadTask.cancel()`, so a successful load
        // never sees a spurious cancellation.
        let downloadTimeout = Self.downloadStallTimeoutSeconds
        let prepareTimeout = Self.prepareStallTimeoutSeconds
        let stallWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if Task.isCancelled { return }
                let (stalled, effectiveTimeout) = await MainActor.run { () -> (Bool, TimeInterval) in
                    guard let last = self.lastLoadProgressAt else { return (false, prepareTimeout) }
                    // Per-phase timeout selection. Defaults to the
                    // shorter "preparing" budget when no phase event
                    // has landed yet — an early stall (before download
                    // even starts ticking) should fail fast, not wait
                    // out the longer download budget.
                    let timeout: TimeInterval = {
                        switch self.currentLoadPhase {
                        case .downloading: return downloadTimeout
                        case .preparing:   return prepareTimeout
                        case .none:        return prepareTimeout
                        }
                    }()
                    return (Date().timeIntervalSince(last) >= timeout, timeout)
                }
                if stalled {
                    self.log.warning("Runtime: load stalled for >\(effectiveTimeout, format: .fixed(precision: 0))s for '\(modelID, privacy: .public)' — cancelling")
                    // Hop to main actor *before* cancelling so the
                    // error handler observes the flag set. If we
                    // cancelled first the loadTask could throw before
                    // the hop landed, and the failure would render as
                    // a plain user-cancellation rather than a stall.
                    await MainActor.run {
                        self.loadStallTripped = true
                        // Record the timeout that actually fired so
                        // the error message in the catch handler can
                        // quote the right number (download vs prepare
                        // budgets differ by ~2×).
                        self.loadStallTimeoutValue = effectiveTimeout
                    }
                    loadTask.cancel()
                    return
                }
            }
        }

        do {
            try await loadTask.value
            stallWatchdog.cancel()
            mlxLoadProgress = nil
            lastLoadProgressAt = nil
            currentLoadPhase = nil
            activeModel = model
            state = .ready(modelID: model.id)
            // Clear the risky-verdict crumb only if the load actually
            // succeeded — `.risky` stays on the manager when the load
            // failed (Diagnostics needs the verdict to correlate).
            if case .safe = lastFeasibilityVerdict {
                lastFeasibilityVerdict = nil
            }
            log.info("Runtime: '\(model.id, privacy: .public)' loaded successfully")

            // Fire-and-forget smoke test: ask the model to produce a
            // single short reply and log whether it actually streams
            // tokens. Cheap (one token most of the time) and surfaces
            // a corrupted checkpoint immediately instead of waiting
            // for the user to hit a garbage reply.
            //
            // We DON'T flip state on failure — a smoke-test miss
            // doesn't necessarily mean every future generation will
            // fail (could be a transient cold-start issue with KV
            // cache prefill). The log line is enough signal for
            // Diagnostics + Console.app to correlate after the fact.
            //
            // Deferred 200ms so a user who taps send the instant the
            // model becomes ready wins the busy-flag race; the smoke
            // test will see `generationInProgress` and silently skip.
            Task.detached { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                await self?.runSmokeTest(for: model)
            }
        } catch is CancellationError {
            stallWatchdog.cancel()
            mlxLoadProgress = nil
            mlxLoadTask = nil
            // Distinguish "user/lifecycle cancelled" from "stall watchdog
            // cancelled" so the diagnostic state is honest. The watchdog
            // sets `loadStallTripped` right before it fires; reading +
            // resetting it here is race-free because the watchdog has
            // already returned by the time `loadTask.value` throws.
            if loadStallTripped {
                loadStallTripped = false
                let firedTimeout = Int(loadStallTimeoutValue ?? Self.prepareStallTimeoutSeconds)
                loadStallTimeoutValue = nil
                state = .failed(modelID: model.id, reason: "Načtení modelu se zastavilo (žádný progress >\(firedTimeout) s). Zkontroluj připojení a zkus znovu.")
                log.error("Runtime: Load stall-cancelled for '\(model.id, privacy: .public)' (timeout=\(firedTimeout)s)")
            } else {
                state = .idle
                log.info("Runtime: Load cancelled for '\(model.id, privacy: .public)'")
            }
            lastLoadProgressAt = nil
            currentLoadPhase = nil
        } catch {
            stallWatchdog.cancel()
            mlxLoadProgress = nil
            mlxLoadTask = nil
            lastLoadProgressAt = nil
            currentLoadPhase = nil
            state = .failed(modelID: model.id, reason: Self.humanisedLoadError(error))
            log.error("Runtime: Load failed for '\(model.id, privacy: .public)': \(error.localizedDescription, privacy: .public)")

            // Broken-cache hook. When the error is one of the typed
            // "directory is structurally broken" cases, notify the
            // host so it can reset the catalog + wipe the bad cache.
            // The user's next view then shows a clean Download CTA
            // instead of a stale Load button that would just fail
            // identically next time. Wrapped in a check rather than
            // always fired so a network or memory error doesn't get
            // miscategorised as bad-cache and trigger a destructive
            // disk wipe.
            if let runtimeError = error as? RuntimeError {
                switch runtimeError {
                case .missingFiles, .invalidModelDirectory:
                    let reason = Self.humanisedLoadError(error)
                    onBrokenCacheDetected?(model, reason)
                default:
                    break
                }
            }
        }
        mlxLoadTask = nil
    }

    /// Maps a raw load error to a short, user-facing Czech string.
    /// The raw `error.localizedDescription` from MLX-Swift can contain full
    /// NSURLError UserInfo blobs (including 2 000-character pre-signed S3 URLs)
    /// or English-only MLX messages — neither is suitable for direct display.
    private static func humanisedLoadError(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()

        // Network drop during MLX's own internal download (user-added URL models
        // whose weights MLX fetches directly, e.g. via HuggingFace XET/CAS).
        let networkCodes: [URLError.Code] = [
            .networkConnectionLost, .notConnectedToInternet, .timedOut,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .dataNotAllowed, .internationalRoamingOff,
        ]
        if let urlErr = error as? URLError, networkCodes.contains(urlErr.code) {
            return "Připojení bylo přerušeno při stahování modelu. Zkontroluj Wi-Fi/mobilní data a zkus znovu."
        }
        // NSURLError wrapped inside a generic Swift error (MLX wraps it).
        if desc.contains("network connection was lost") || desc.contains("not connected to the internet")
            || desc.contains("code=-1005") || desc.contains("code=-1009") {
            return "Připojení bylo přerušeno při stahování modelu. Zkontroluj Wi-Fi/mobilní data a zkus znovu."
        }

        // Out-of-memory — MLX throws an English message; map it to Czech.
        if desc.contains("out of memory") || desc.contains("memory allocation") || desc.contains("cannot allocate")
            || desc.contains("allocation failed") || desc.contains("enomem") {
            return "Zařízení nemá dostatek volné paměti pro tento model. Zavři ostatní aplikace a zkus znovu."
        }

        // Model-file corruption / incomplete download (e.g. XET pointer downloaded
        // instead of actual safetensors, or file truncated mid-transfer).
        if desc.contains("invalid header") || desc.contains("magic") || desc.contains("safetensor")
            || desc.contains("corrupt") || desc.contains("unexpected eof") {
            return "Soubory modelu jsou poškozené nebo neúplné. Smaž model a stáhni ho znovu."
        }

        // Fallback: trim to a reasonable length so a 2 000-char URL doesn't fill the cell.
        let raw = error.localizedDescription
        if raw.count > 200 {
            return String(raw.prefix(200)) + "…"
        }
        return raw
    }

    /// Stall-watchdog deadlines, picked separately per load phase:
    ///   - **Download** (90 s): a single chunk request on cellular can
    ///     legitimately stall for 60+ s during a slow TLS handshake
    ///     or a CDN failover; we want to tolerate that before giving
    ///     up. The total download can still take many minutes — only
    ///     the *gap between progress ticks* is bounded.
    ///   - **Preparing** (45 s): no fractional progress is emitted
    ///     during Metal pipeline compile + tokenizer load; the
    ///     watchdog is the only thing standing between a genuinely
    ///     stuck compile and a user staring at a spinner forever.
    ///     45 s comfortably covers a healthy compile on every iPhone
    ///     we've tested while catching the truly stuck case.
    ///   - **Initial / no phase observed yet** (45 s): same as
    ///     preparing — if we haven't seen a single tick that long
    ///     after kick-off, something is wrong before download even
    ///     started.
    private static let downloadStallTimeoutSeconds: TimeInterval = 90
    private static let prepareStallTimeoutSeconds: TimeInterval = 45
    /// Convenience for log messages and the diagnostic strings that
    /// quote a single number — picks the *longer* of the two so the
    /// surfaced bound is the user's worst-case patience.
    private static var loadStallTimeoutSeconds: TimeInterval {
        max(downloadStallTimeoutSeconds, prepareStallTimeoutSeconds)
    }

    /// Wall-clock timestamp of the most recent progress tick from the
    /// active load. `nil` between loads. The stall watchdog reads this
    /// to detect "no progress in N seconds". Lives on the main actor
    /// because the progress callback hops there to update
    /// `mlxLoadProgress`; sharing the actor avoids a separate lock.
    private var lastLoadProgressAt: Date?

    /// Current load phase as last observed by the progress callback.
    /// Drives the per-phase timeout selection in the stall watchdog:
    /// download stalls get more rope (slow chunks are normal) than
    /// preparing stalls (which signal a stuck Metal compile). `nil`
    /// before the first phase event arrives — treated as "preparing"
    /// by the watchdog (early stall = before download starts =
    /// shorter rope).
    private var currentLoadPhase: MLXLoadPhase?

    /// Set to `true` by the stall watchdog *before* it cancels the
    /// load task. The error handler reads + clears it so the failure
    /// state can distinguish "watchdog tripped" from "user / lifecycle
    /// cancelled". Safe to read without a lock — both writer (watchdog
    /// hop to main actor) and reader run on `@MainActor`.
    private var loadStallTripped: Bool = false

    /// The actual timeout value (seconds) that the watchdog fired on.
    /// Recorded by the watchdog right before cancellation so the user-
    /// facing failure message can quote download vs preparing budget
    /// instead of a fixed legacy "60 s" string. `nil` between loads
    /// or when the watchdog hasn't fired.
    private var loadStallTimeoutValue: TimeInterval?

    // MARK: - Unload

    /// Cancels any in-flight model load and unloads the active model.
    ///
    /// Waits for the current operation to observe cancellation before
    /// starting the unload, so calling `unload()` immediately after
    /// `load()` cannot leave the runtime in a half-initialised state.
    func unload() async {
        // Cancel the inner load task first so the outer operationTask wrapper
        // finishes quickly via the CancellationError path, freeing the slot.
        mlxLoadTask?.cancel()
        mlxLoadTask = nil

        // Bounded wait — Metal pipeline compile occasionally outlives a
        // cancellation request by a few seconds; we'd rather proceed with
        // the user-visible unload than block on it. See `awaitOperation`.
        await awaitOperation(timeout: 1.5, reason: "unload")
        if state == .idle { return }

        let task = Task<Void, Never> { [weak self] in await self?._performUnload() }
        operationTask = task
        await task.value
        if operationTask == task { operationTask = nil }
    }

    private func _performUnload() async {
        let unloadingID = activeModel?.id ?? "none"
        log.info("Runtime: Unloading '\(unloadingID, privacy: .public)'")
        state = .unloading
        await runtime.unload()
        activeModel = nil
        state = .idle
        // Drop any stale verdict from the previous load. The next load
        // will repopulate it via the oracle.
        lastFeasibilityVerdict = nil
    }

    // MARK: - Memory oracle

    /// Tri-state preflight verdict for loading a model on the current
    /// device + memory state. Single source of truth for "is it safe to
    /// load this right now?" — consumed by `_performLoad` (gates load)
    /// and exposed via `Self.evaluateFeasibility(...)` for UI consumers
    /// that want to anticipate the outcome (e.g. download confirm
    /// dialog).
    enum LoadFeasibility: Equatable, Sendable {
        /// Available memory comfortably covers the model weights plus
        /// the profile's safety margin. Proceed silently.
        case safe(headroomBytes: Int64)
        /// Weights fit raw RAM, but the profile's safety margin would
        /// be eaten. Load may succeed but is one Jetsam ping away
        /// from being killed. UI should surface a "Může selhat kvůli
        /// paměti" warning; the load itself is allowed to proceed
        /// because the user explicitly chose this model.
        case risky(requiredBytes: Int64, availableBytes: Int64)
        /// Even raw model weights exceed available memory. Loading
        /// would almost certainly trigger an immediate OOM. Block.
        case cannotLoad(requiredBytes: Int64, availableBytes: Int64)

        /// `true` for `.safe` and `.risky` — i.e. the load should be
        /// attempted. `.cannotLoad` is the only veto.
        var permitsLoad: Bool {
            if case .cannotLoad = self { return false }
            return true
        }
    }

    /// Memory oracle — pure function over `(model, profile, available)`.
    /// Exposed as a static so callers without a `RuntimeManager` (UI
    /// preview, tests, alternate entry points) can evaluate the same
    /// verdict the load gate will see. Pass `nil` for `available` to
    /// have the oracle query `os_proc_available_memory()` itself.
    ///
    /// `nonisolated` so the load gate can invoke it from a detached
    /// Task without bouncing back onto the `@MainActor` — the function
    /// is a pure read of `model.sizeBytes` + the immutable safety table
    /// + a sysctl call.
    ///
    /// Sizing model: the safety factor (profile-dependent: 1.3 / 1.5 /
    /// 1.8) is the "comfortable" multiplier — it accounts for KV cache,
    /// Metal buffers, and headroom for the rest of the app. The raw
    /// `model.sizeBytes` is the absolute floor below which the model
    /// cannot even be mapped.
    nonisolated static func evaluateFeasibility(
        for model: LocalModel,
        profile: PerformanceProfile,
        available: Int64? = nil
    ) -> LoadFeasibility? {
        guard model.sizeBytes > 0 else { return nil }
        guard let avail = available ?? availableMemoryBytes() else { return nil }
        let raw = model.sizeBytes
        let safe = Int64(Double(model.sizeBytes) * memorySafetyFactor(for: profile))
        // mmap headroom: MLX memory-maps weight files, so read-only weight
        // pages are file-backed (clean) and can be paged in/out by the VM —
        // they don't count fully against `os_proc_available_memory()`'s
        // dirty budget. A model whose raw size modestly exceeds the budget
        // can therefore still load (other apps do it), and architectures
        // like Gemma 3n (Per-Layer Embeddings) have a resident footprint
        // well below file size. So the "impossible" floor is raw scaled
        // down by a paging-tolerance factor rather than the raw size itself.
        // Everything between the floor and the safe margin is `.risky`
        // (allowed under the user's explicit opt-in), not a hard refusal.
        let mmapFloor = Int64(Double(raw) * 0.66)
        if avail >= safe {
            return .safe(headroomBytes: avail - safe)
        } else if avail >= mmapFloor {
            return .risky(requiredBytes: safe, availableBytes: avail)
        } else {
            return .cannotLoad(requiredBytes: raw, availableBytes: avail)
        }
    }

    /// Convenience for instance call sites — same as
    /// `Self.evaluateFeasibility(for:profile:available:)` with the
    /// instance's current `performanceProfile`.
    func feasibility(for model: LocalModel) -> LoadFeasibility? {
        Self.evaluateFeasibility(for: model, profile: performanceProfile)
    }

    /// Last preflight verdict from the most recent `load()` call.
    /// Cleared on successful load completion (so a once-risky load
    /// that actually finished doesn't keep flashing the warning).
    /// Read by `DeveloperDiagnosticsView`.
    @Published private(set) var lastFeasibilityVerdict: LoadFeasibility?

    // MARK: - Memory estimates (UI side)

    /// Coarse-grained KV cache size estimate.
    ///
    /// We don't have access to the model's per-layer dimensions until
    /// after it's loaded, and even then MLX-Swift doesn't expose them
    /// uniformly. A pragmatic proxy: KV bytes-per-token scales roughly
    /// with model weight size. Empirically, for 4-bit quantised models
    /// in the 0.5 GB – 5 GB range, the per-token cost lands near
    /// `model.sizeBytes × 5 × 10⁻⁵`:
    ///   - 700 MB Llama-3.2-1B → ~35 KB/token → ~70 MB @ 2k context
    ///   - 1.9 GB Llama-3.2-3B → ~95 KB/token → ~190 MB @ 2k context
    ///   - 4.5 GB Llama-3.1-8B → ~225 KB/token → ~460 MB @ 2k context
    ///
    /// Errs on the high side so the "total memory" estimate shown in
    /// the model detail sheet doesn't undersell the load cost. Returns
    /// 0 if `model.sizeBytes` is unknown.
    nonisolated static func estimatedKVCacheBytes(
        for model: LocalModel,
        contextLength: Int? = nil
    ) -> Int64 {
        guard model.sizeBytes > 0 else { return 0 }
        let ctx = contextLength ?? model.contextLength
        guard ctx > 0 else { return 0 }
        let bytesPerToken = Int64(Double(model.sizeBytes) * 5e-5)
        return bytesPerToken * Int64(ctx)
    }

    /// Total estimated resident memory required to actually generate
    /// with this model at the given context: weights + KV cache.
    /// **Does not** include the profile's safety margin — that's
    /// applied separately by the oracle.
    nonisolated static func estimatedTotalMemoryBytes(
        for model: LocalModel,
        contextLength: Int? = nil
    ) -> Int64 {
        model.sizeBytes + estimatedKVCacheBytes(for: model, contextLength: contextLength)
    }

    // MARK: - Memory headroom (coarse device-wide signal)

    /// Coarse "how comfortable is this device with LLM work right now"
    /// signal. Drives the `ModelsView` headroom strip and feeds into
    /// the risk dialog wording.
    ///
    /// Computed against a **reference model** (typical iPhone-safe 4-bit
    /// 3B, ≈ 2 GB) rather than any specific catalog entry, so the strip
    /// stays stable as the user scrolls the catalog and isn't biased by
    /// whichever model happens to be in view.
    enum MemoryHeadroom: Equatable, Sendable {
        case high      // available ≥ reference × 1.5 — comfortable
        case medium    // available ≥ reference × 1.0
        case low       // available < reference
        case unknown   // os_proc_available_memory returned 0 / not on device

        var localizedLabel: String {
            switch self {
            case .high:    return "vysoká"
            case .medium:  return "střední"
            case .low:     return "nízká"
            case .unknown: return "neznámá"
            }
        }
    }

    /// Reference model footprint the headroom strip compares against.
    /// Picked as "the smallest model we'd actually recommend on iPhone"
    /// — ≈ 2 GB (Llama-3.2-3B class). Tweaking this changes how lenient
    /// the headroom buckets are.
    nonisolated static let headroomReferenceBytes: Int64 = 2_000_000_000

    /// Snapshot of the device's current memory headroom. Pure function
    /// modulo `availableMemoryBytes()`, which is a single sysctl call —
    /// callers should still run this off `@MainActor` (the UI does that
    /// via `Task.detached`).
    ///
    /// **Display vs. gate.** This function is for the *display* strip in
    /// `ModelsView` — it answers "is there room for one more reference
    /// model right now?". The load gate (`evaluateFeasibility`) applies
    /// the profile's safety factor on top; doing it here too painted
    /// every iPhone in the catalog as "low" because `os_proc_available_memory`
    /// returns the per-process limit (~3–5 GB on consumer iPhones), and
    /// `2 GB × 1.5 = 3 GB` is right on that boundary even when physical
    /// memory is plentiful. Display compares against the raw reference;
    /// the gate keeps the safety margin where it matters.
    nonisolated static func currentHeadroom(
        profile: PerformanceProfile,
        available: Int64? = nil
    ) -> MemoryHeadroom {
        guard let avail = available ?? availableMemoryBytes() else { return .unknown }
        let reference = headroomReferenceBytes
        if avail >= reference + reference / 2 {  // reference × 1.5
            return .high
        } else if avail >= reference {
            return .medium
        } else {
            return .low
        }
    }

    /// One-line per-load decision log. Captures the things we wish we
    /// could see when debugging "why does this model behave differently"
    /// without attaching Xcode:
    ///   - performance profile in effect
    ///   - template source (GGUF metadata vs built-in family fallback)
    ///   - effective context length (min of catalog and metadata)
    private func logLoadDecision(for model: LocalModel) {
        let meta = ggufMetadataProvider?(model.id)
        let templateSource: String = {
            switch model.format {
            case .mlx:  return "tokenizer snapshot (MLX ChatSession)"
            case .coreMLPackage:
                // SD bundles have no chat template — image
                // generation. This branch should never fire in
                // practice (RoutingRuntime rejects `.coreML` before
                // we get here), but we surface a coherent string
                // so any future log-grep tooling doesn't see "switch
                // covered all cases" diagnostic chatter.
                return "n/a (Core ML image pipeline)"
            case .gguf:
                if meta?.chatTemplate != nil { return "GGUF metadata" }
                return "built-in template for family '\(model.family)'"
            }
        }()
        let effectiveCtx: Int = {
            if let metaCtx = meta?.contextLength { return min(model.contextLength, metaCtx) }
            return model.contextLength
        }()
        let arch = meta?.architecture ?? "(unknown)"
        log.info("Runtime: Load decision for '\(model.id, privacy: .public)' — profile=\(self.performanceProfile.rawValue, privacy: .public) template=\(templateSource, privacy: .public) ctx=\(effectiveCtx) arch=\(arch, privacy: .public)")
    }

    /// Returns the number of bytes the OS considers available for this process
    /// via `os_proc_available_memory()` (iOS 14+). Returns `nil` on error.
    /// Public so the memory oracle (`Self.evaluateFeasibility`) and any
    /// future fallback path can share a single implementation. `nonisolated`
    /// so it's callable from off-actor code paths.
    nonisolated static func availableMemoryBytes() -> Int64? {
        let bytes = _os_proc_available_memory()
        guard bytes > 0 else { return nil }
        return Int64(min(bytes, UInt(Int64.max)))
    }

    // MARK: - MLX load cancellation

    /// Cancels an in-flight MLX load (download or initialization).
    ///
    /// Cancellation is cooperative — the Hub downloader may finish the current
    /// chunk before stopping. Any partial cache is safe: Phase 3 detection
    /// classifies it as `.partial` → `.notInstalled` on next reconcile.
    func cancelMLXLoad() {
        mlxLoadTask?.cancel()
        mlxLoadTask = nil
    }

    // MARK: - State helpers

    /// Syncs `activeModel` and `state` to `.idle` without calling
    /// `runtime.unload()`. Use this when the runtime has already auto-unloaded
    /// (memory pressure, background) and `AppContainer` needs to reconcile the
    /// observable state without triggering a second unload call.
    func clearState() {
        activeModel = nil
        state = .idle
    }

    // MARK: - Generate passthrough

    /// Thin passthrough so services stay decoupled from the concrete runtime.
    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        runtime.generate(prompt: prompt, parameters: parameters)
    }

    // MARK: - Post-load smoke test

    /// Tiny "hello" generation right after a successful load. Logs
    /// the elapsed time + first-token latency + total tokens to
    /// `HHLog.runtime`. Doesn't modify state — a corrupted checkpoint
    /// shows up immediately in Console.app instead of waiting for
    /// the user to send a real prompt.
    ///
    /// Failure modes detected:
    ///   * Stream errors (model file broken, tokenizer init failed
    ///     post-load, OOM at first decode) — logged as `.error`.
    ///   * Zero tokens streamed within 10 s — logged as `.warning`.
    ///   * First-token latency > 5 s — logged as `.warning` (slow
    ///     prefill on this device).
    private func runSmokeTest(for model: LocalModel) async {
        let prompt = RuntimePrompt(
            stableSystemPrompt: "You are a helpful assistant. Reply with one short word.",
            volatileSystemPrompt: "",
            messages: [RuntimeMessage(role: .user, content: "Hi")]
        )
        // Deterministic + tiny: argmax-ish via low temp, hard ceiling
        // at 4 tokens. forceStateless so the smoke test never pollutes
        // the real KV-cache prefix.
        var parameters = RuntimeParameters(
            maxTokens: 4,
            temperature: 0.0,
            topP: 1.0,
            stopSequences: []
        )
        parameters.forceStateless = true
        parameters.conversationID = UUID()
        // Fixed seed: smoke test output should be identical across
        // launches for the same checkpoint. If a future run produces
        // different tokens for the same model file, that's a corruption
        // signal worth investigating.
        parameters.seed = 42

        let startedAt = Date()
        var firstTokenAt: Date?
        var tokens = 0
        var streamed = ""

        do {
            for try await event in runtime.generate(prompt: prompt, parameters: parameters) {
                if Task.isCancelled { return }
                switch event {
                case .token(let piece):
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    tokens += 1
                    streamed += piece
                case .finished:
                    let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    let firstMs = firstTokenAt.map { Int($0.timeIntervalSince(startedAt) * 1000) } ?? -1
                    if tokens == 0 {
                        log.warning("Smoke test (\(model.id, privacy: .public)): 0 tokens in \(totalMs, privacy: .public)ms — checkpoint may be corrupted")
                    } else {
                        log.info("Smoke test (\(model.id, privacy: .public)): \(tokens, privacy: .public) tokens / first \(firstMs, privacy: .public)ms / total \(totalMs, privacy: .public)ms / output=\"\(streamed.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)\"")
                        if firstMs > 5000 {
                            log.warning("Smoke test (\(model.id, privacy: .public)): slow first token (\(firstMs, privacy: .public)ms) — device may be RAM-pressured")
                        }
                    }
                    return
                case .warning:
                    break
                }
            }
        } catch let error as RuntimeError where error == .generationInProgress {
            // The user beat us to it — already mid-real-conversation,
            // which is itself proof the model can stream. Silent skip.
            log.debug("Smoke test (\(model.id, privacy: .public)) skipped — runtime already busy with user turn")
        } catch {
            log.error("Smoke test (\(model.id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - KV-cache session management

    /// Removes the KV-cache session for `conversationID`.
    /// No-op when the runtime doesn't support session tracking (e.g. mock).
    func invalidateSession(for conversationID: UUID) async {
        await runtime.invalidateSession(for: conversationID)
    }

    // MARK: - Lifecycle forwarding

    /// Forwards a memory-pressure event to the runtime.
    ///
    /// Cancels any in-flight load first, then waits for the current operation
    /// to complete before forwarding the event to the runtime. If the runtime
    /// auto-unloads the model in response, syncs state to `.idle`.
    ///
    /// - Returns: The model that was unloaded, or `nil` if no model was loaded
    ///   or the runtime chose not to unload.
    @discardableResult
    func handleMemoryPressure() async -> LocalModel? {
        // Cancel inner load immediately — cooperative, returns quickly.
        mlxLoadTask?.cancel()
        mlxLoadTask = nil
        // Wait for the operation wrapper to observe cancellation, but cap
        // it so a stuck Metal compile cannot trap us inside the watchdog
        // window (see `awaitOperation(timeout:reason:)`).
        await awaitOperation(timeout: 1.5, reason: "memoryPressure")

        let modelBeforeEvent = activeModel
        let id = modelBeforeEvent?.id ?? "none"
        log.warning("Runtime: Memory pressure — unloading '\(id, privacy: .public)'")
        await runtime.handleMemoryPressure()
        guard modelBeforeEvent != nil, runtime.loadedModel == nil else { return nil }
        clearState()
        return modelBeforeEvent
    }

    /// Soft tier of memory pressure — drop cheap caches (KV reuse
    /// session, sampler scratch) without dropping the model weights.
    /// Returns `true` if the runtime had anything to release; the
    /// caller can use this for diagnostics but the soft path is a
    /// best-effort hint, not a hard contract.
    ///
    /// Safe to call during an in-flight load (no wait on operationTask)
    /// because the soft path doesn't touch the loader — it only flushes
    /// session-level scratch held by the runtime.
    func handleSoftMemoryPressure() async {
        let id = activeModel?.id ?? "none"
        log.info("Runtime: Soft memory pressure — trimming caches for '\(id, privacy: .public)'")
        await runtime.trimMemoryCaches()
    }

    /// Snapshot of whether the underlying runtime is currently producing
    /// tokens. Used by `AppContainer`'s two-tier pressure policy to
    /// defer a hard unload until the active turn finishes (interrupting
    /// a streaming reply is worse UX than completing it).
    var isGenerating: Bool {
        runtime.isCurrentlyGenerating
    }

    /// Real BPE token count via the active model's tokenizer.
    /// Async because the underlying MLX container is an actor.
    /// Returns `nil` when no model is loaded or the runtime doesn't
    /// expose a tokenizer (mock / preview).
    ///
    /// Recommended call sites:
    ///   - Per-turn budget calibration (compare heuristic vs real)
    ///   - Developer Diagnostics ("show me the ground truth")
    ///   - Test fixtures that need real numbers
    ///
    /// Do NOT call this from the per-streaming-token watchdog; the
    /// heuristic in `PromptTokenBudgeter` is what that path uses.
    func realTokenCount(of text: String) async -> Int? {
        await runtime.realTokenCount(of: text)
    }

    /// Forwards a scene-background event to the runtime.
    ///
    /// Unlike pressure events, background unloading is policy-dependent —
    /// the runtime may choose to keep the model in memory. Cancels any
    /// in-flight load before forwarding so the runtime never starts up in
    /// the background.
    ///
    /// - Returns: The model that was unloaded, or `nil` if no model was loaded
    ///   or the runtime chose not to unload.
    @discardableResult
    func handleBackground() async -> LocalModel? {
        mlxLoadTask?.cancel()
        mlxLoadTask = nil
        await awaitOperation(timeout: 1.5, reason: "background")

        let modelBeforeEvent = activeModel
        await runtime.handleBackground()
        guard modelBeforeEvent != nil, runtime.loadedModel == nil else { return nil }
        clearState()
        return modelBeforeEvent
    }

    /// Unconditionally force-unloads the active model on thermal-critical.
    ///
    /// At `.critical` the OS is about to throttle aggressively and may kill
    /// the app. Holding the model in memory only makes termination more
    /// likely, so we cancel any in-flight load and unload immediately.
    ///
    /// - Returns: The model that was unloaded, or `nil` if nothing was loaded.
    @discardableResult
    func handleThermalCritical() async -> LocalModel? {
        mlxLoadTask?.cancel()
        mlxLoadTask = nil
        await awaitOperation(timeout: 1.5, reason: "thermalCritical")

        guard let modelBeforeEvent = activeModel else { return nil }
        log.critical("Runtime: Thermal critical — force-unloading '\(modelBeforeEvent.id, privacy: .public)'")
        state = .unloading
        await runtime.unload()
        clearState()
        return modelBeforeEvent
    }

    // MARK: - Operation wait with timeout

    /// Bounded wait for the in-flight `operationTask`. The original
    /// pattern `if let op = operationTask { await op.value }` could
    /// stall the main actor indefinitely when a detached load was
    /// mid Metal-pipeline compile — long enough to trip the iOS
    /// watchdog (0x8BADF00D, observed in production).
    ///
    /// Returns as soon as either the operation completes OR the
    /// timeout elapses. When the timeout fires we **drop** the slot
    /// (the inner task has already been cancelled by the caller and
    /// will tear itself down asynchronously) — there is no risk of a
    /// new operation overlapping, because `operationTask` is the only
    /// gate and the next public method will install its own task.
    ///
    /// The `reason` tag identifies the calling lifecycle path
    /// ("background", "memoryPressure", "thermalCritical", "unload") so
    /// the emitted `loaderCancelTimeout` telemetry event can be grouped
    /// in DeveloperDiagnostics when multiple lifecycle events stack.
    private func awaitOperation(timeout seconds: TimeInterval, reason: String) async {
        guard let op = operationTask else { return }
        let timeoutNS = UInt64(max(0, seconds) * 1_000_000_000)
        let raced = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { await op.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNS)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !raced {
            log.warning("Runtime: awaitOperation(\(reason, privacy: .public)) timed out after \(seconds, format: .fixed(precision: 2))s — releasing slot to honour lifecycle event")
            // Detach the slot so subsequent public methods don't queue
            // behind a load that already missed its window.
            if operationTask == op { operationTask = nil }
            // Surface to subscribers (DeveloperDiagnostics renders a
            // recent-telemetry list). The await is on an actor send,
            // not a network round-trip, so it doesn't extend our own
            // exit from the lifecycle window.
            await runtime.telemetry.emit(.loaderCancelTimeout(reason: reason, timeoutSeconds: seconds))
        }
    }
}

// MARK: - LoadProgressThrottle

/// Coalesces high-frequency progress callbacks from the MLX loader so
/// the main actor isn't flooded with redundant `Task @MainActor` hops.
///
/// **Policy.**
///   - Same phase case (e.g. consecutive `.downloading(_)` ticks):
///     emit at most once every `minIntervalMs`. The display refreshes
///     at 60 Hz; emitting at 20 Hz is already over-fresh.
///   - **Different phase case** (e.g. `.downloading` → `.preparing`):
///     always emit. Phase transitions are the moment the UI needs to
///     flip from "Stahování X %" to "Příprava…"; throttling them
///     would leave the progress bar visually stuck.
///
/// Lives outside the `@MainActor`-isolated `RuntimeManager` because
/// the callback runs on the loader's detached executor; reaching back
/// onto MainActor *just* to check the throttle would defeat the
/// purpose. Thread safety via `NSLock` keeps the contract obvious —
/// no actor hop required to read or update the state.
///
/// `internal` (not `private`) so the unit tests in
/// `LoadProgressThrottleTests` can construct it and exercise the
/// time-window math directly. The class is purely a utility for the
/// runtime manager; nothing outside the test bundle should use it.
final class LoadProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmittedAt: Date?
    private var lastPhaseCase: PhaseCase?
    private let minInterval: TimeInterval

    /// Identity for `MLXLoadPhase` cases — strips the associated value
    /// on `.downloading(fraction:)` so the throttle compares "kind",
    /// not "kind + payload". Without this, every tick of a varying
    /// fraction would register as a phase transition and skip the
    /// throttle. Internal so the unit tests below can construct it.
    fileprivate enum PhaseCase: Equatable {
        case downloading
        case preparing
    }

    init(minIntervalMs: Int = 100) {
        self.minInterval = TimeInterval(minIntervalMs) / 1000
    }

    /// Returns `true` when the progress callback should hop to the
    /// main actor and update UI state. Mutates the internal state on
    /// every call, so the caller must respect the return value (a
    /// second call with the same input may return `false`).
    func shouldEmit(phase: MLXLoadPhase) -> Bool {
        let phaseCase: PhaseCase = {
            switch phase {
            case .downloading: return .downloading
            case .preparing:   return .preparing
            }
        }()
        lock.lock()
        defer { lock.unlock() }
        // Phase transition → always emit. This covers the initial
        // .preparing arrival when there's no prior history, and the
        // .downloading → .preparing flip at end of download.
        if lastPhaseCase != phaseCase {
            lastPhaseCase = phaseCase
            lastEmittedAt = Date()
            return true
        }
        // Same phase → throttle. If never emitted in this scope (we
        // observed a phase but haven't recorded an emission yet, which
        // shouldn't happen but is defended against), emit and seed.
        guard let last = lastEmittedAt else {
            lastEmittedAt = Date()
            return true
        }
        let now = Date()
        if now.timeIntervalSince(last) >= minInterval {
            lastEmittedAt = now
            return true
        }
        return false
    }
}
