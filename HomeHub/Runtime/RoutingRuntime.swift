import Foundation
import os

/// Dispatches calls to the appropriate backend based on `LocalModel.backend`.
///
/// **Backend availability** is read from `RuntimeBackendAvailability` (the
/// single source of truth) — UI-side gating goes through
/// `LocalModel.isUsableInThisBuild`, runtime-side gating goes through this
/// router. Loading a model whose backend isn't linked into the build throws
/// `RuntimeError.backendUnavailable(...)` with a precise actionable message
/// (built once in `RuntimeError`'s `errorDescription` so wording stays in
/// one place).
///
/// Thread-safety: `activeBackend` is mutated only through `load()` and
/// `unload()`. In practice all callers go through `RuntimeManager` which is
/// `@MainActor`, serialising access.
final class RoutingRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "router"

    #if HOMEHUB_LLAMA_RUNTIME
    private let llamaCpp: LlamaCppRuntime?
    #endif
    private let mlx: MLXRuntime

    private let log = Logger(subsystem: "HomeHub", category: "RoutingRuntime")

    /// The currently active backend.
    private var activeBackend: (any LocalLLMRuntime)?

    var loadedModel: LocalModel? { activeBackend?.loadedModel }

    /// Telemetry is aggregated from the currently active backend.
    var telemetry: RuntimeTelemetry { activeBackend?.telemetry ?? .noOp }

    #if HOMEHUB_LLAMA_RUNTIME
    init(llamaCpp: LlamaCppRuntime?, mlx: MLXRuntime) {
        self.llamaCpp = llamaCpp
        self.mlx = mlx
    }
    #else
    init(mlx: MLXRuntime) {
        self.mlx = mlx
    }
    #endif

    // MARK: - Load

    func load(model: LocalModel) async throws {
        try await loadWithProgress(model: model, progressHandler: nil)
    }

    /// Routes the load to the correct backend, forwarding phase progress.
    ///
    /// Two unload scenarios before the new load:
    /// - **Backend switch** (e.g. `.llamaCpp` → `.mlx`): old backend is unloaded.
    /// - **Model switch on same backend** (e.g. MLX model A → MLX model B):
    ///   backend is also unloaded first to avoid holding two multi-GB models in
    ///   shared GPU memory simultaneously during the new load.
    func loadWithProgress(
        model: LocalModel,
        progressHandler: (@Sendable (MLXLoadPhase) -> Void)?
    ) async throws {
        // Reject backends that aren't linked BEFORE doing any work. The
        // wording is owned by `RuntimeError.backendUnavailable` so UI and
        // CLI surfaces stay in sync.
        guard RuntimeBackendAvailability.isAvailable(model.backend) else {
            log.warning("RoutingRuntime: \(model.backend.rawValue) backend not linked into this build for '\(model.id, privacy: .public)'")
            throw RuntimeError.backendUnavailable(
                modelName: model.displayName,
                backend: model.backend
            )
        }

        let targetBackend: any LocalLLMRuntime
        switch model.backend {
        case .llamaCpp:
            #if HOMEHUB_LLAMA_RUNTIME
            // `RuntimeBackendAvailability.isAvailable` already returned true, but
            // the property may legitimately be nil if the runtime was injected
            // as such (e.g. a future flag that compiles llama in but skips
            // wiring it). Treat that as backend unavailable too.
            guard let llamaCpp else {
                throw RuntimeError.backendUnavailable(
                    modelName: model.displayName,
                    backend: .llamaCpp
                )
            }
            targetBackend = llamaCpp
            #else
            // Unreachable: `isAvailable(.llamaCpp)` is false in this branch.
            throw RuntimeError.backendUnavailable(
                modelName: model.displayName,
                backend: .llamaCpp
            )
            #endif
        case .mlx:
            targetBackend = mlx
        }

        log.info("RoutingRuntime: Routing '\(model.id, privacy: .public)' to '\(targetBackend.identifier, privacy: .public)'")

        if let current = activeBackend {
            let switchingBackend = current !== targetBackend
            let switchingModel  = current.loadedModel?.id != model.id
            if switchingBackend || switchingModel {
                await current.unload()
            }
        }

        activeBackend = targetBackend
        try await targetBackend.loadWithProgress(model: model, progressHandler: progressHandler)
    }

    // MARK: - Unload

    func unload() async {
        await activeBackend?.unload()
        activeBackend = nil
    }

    // MARK: - Generate

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        guard let activeBackend else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: RuntimeError.noModelLoaded)
            }
        }
        return activeBackend.generate(prompt: prompt, parameters: parameters)
    }

    // MARK: - Lifecycle

    func handleMemoryPressure() async {
        await activeBackend?.handleMemoryPressure()
    }

    func handleBackground() async {
        await activeBackend?.handleBackground()
    }

    func invalidateSession(for conversationID: UUID) async {
        await activeBackend?.invalidateSession(for: conversationID)
    }
}
