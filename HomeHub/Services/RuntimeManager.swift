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

    /// Safety factor applied to `model.sizeBytes` in the memory preflight.
    ///
    /// The 1.5× multiplier accounts for deserialization working buffers and
    /// Metal pipeline compilation temporaries that briefly live alongside the
    /// loaded weights during model initialisation.
    ///
    /// This is a static `let` so it can be referenced in `memoryCheck(for:)`
    /// without capturing `self` and can be overridden at the call site when
    /// needed (e.g. tests, or a future user-configurable setting).
    static let memorySafetyFactor: Double = 1.5

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

    // MARK: - Telemetry

    /// Structured telemetry channel for the active runtime.
    var telemetry: RuntimeTelemetry { runtime.telemetry }

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

        // Memory preflight — abort before allocating anything.
        if let check = memoryCheck(for: model) {
            if !check.canLoad {
                let fmt = ByteCountFormatter()
                fmt.allowedUnits = [.useMB, .useGB]
                fmt.countStyle = .file
                log.warning("Runtime: Memory gate FAIL for '\(model.id, privacy: .public)' — need \(check.required) B, have \(check.available) B (×\(Self.memorySafetyFactor))")
                state = .failed(
                    modelID: model.id,
                    reason: "Nedostatek paměti: model potřebuje ≈\(fmt.string(fromByteCount: check.required)), " +
                            "systém hlásí pouze \(fmt.string(fromByteCount: check.available)) volných."
                )
                return
            }
            log.info("Runtime: Memory gate OK for '\(model.id, privacy: .public)' — need \(check.required) B, have \(check.available) B")
        }

        // Phase 3: Load off @MainActor. Task.detached moves Metal pipeline
        // compilation (10–60 s on older hardware) off the UI watchdog's executor.
        let loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            try await self.runtime.loadWithProgress(model: model) { [weak self] phase in
                Task { @MainActor [weak self] in
                    self?.mlxLoadProgress = MLXLoadProgress(modelID: model.id, phase: phase)
                }
            }
        }
        mlxLoadTask = loadTask

        do {
            try await loadTask.value
            mlxLoadProgress = nil
            activeModel = model
            state = .ready(modelID: model.id)
            log.info("Runtime: '\(model.id, privacy: .public)' loaded successfully")
        } catch is CancellationError {
            mlxLoadProgress = nil
            mlxLoadTask = nil
            state = .idle
            log.info("Runtime: Load cancelled for '\(model.id, privacy: .public)'")
        } catch {
            mlxLoadProgress = nil
            mlxLoadTask = nil
            state = .failed(modelID: model.id, reason: error.localizedDescription)
            log.error("Runtime: Load failed for '\(model.id, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
        mlxLoadTask = nil
    }

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

        if let op = operationTask { await op.value }
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
    }

    // MARK: - Memory check

    /// Central memory preflight for loading a model.
    ///
    /// - Parameters:
    ///   - model: The model to evaluate.
    ///   - safetyFactor: Multiplier applied to `model.sizeBytes`. Defaults
    ///     to `RuntimeManager.memorySafetyFactor` (1.5).
    /// - Returns: `(required, available, canLoad)`, or `nil` if the check is
    ///   not applicable (unknown model size, or `os_proc_available_memory`
    ///   returned zero).
    private func memoryCheck(
        for model: LocalModel,
        safetyFactor: Double = RuntimeManager.memorySafetyFactor
    ) -> (required: Int64, available: Int64, canLoad: Bool)? {
        guard model.sizeBytes > 0, let available = Self.availableMemoryBytes() else { return nil }
        let required = Int64(Double(model.sizeBytes) * safetyFactor)
        return (required: required, available: available, canLoad: available >= required)
    }

    /// Returns the number of bytes the OS considers available for this process
    /// via `os_proc_available_memory()` (iOS 14+). Returns `nil` on error.
    private static func availableMemoryBytes() -> Int64? {
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
        // Wait for the operation wrapper to observe cancellation.
        if let op = operationTask { await op.value }

        let modelBeforeEvent = activeModel
        let id = modelBeforeEvent?.id ?? "none"
        log.warning("Runtime: Memory pressure — unloading '\(id, privacy: .public)'")
        await runtime.handleMemoryPressure()
        guard modelBeforeEvent != nil, runtime.loadedModel == nil else { return nil }
        clearState()
        return modelBeforeEvent
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
        if let op = operationTask { await op.value }

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
        if let op = operationTask { await op.value }

        guard let modelBeforeEvent = activeModel else { return nil }
        log.critical("Runtime: Thermal critical — force-unloading '\(modelBeforeEvent.id, privacy: .public)'")
        state = .unloading
        await runtime.unload()
        clearState()
        return modelBeforeEvent
    }
}
