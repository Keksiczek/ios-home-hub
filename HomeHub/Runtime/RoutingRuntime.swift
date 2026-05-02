import Foundation
import os

/// Dispatches calls to the appropriate backend based on model metadata.
///
/// `RoutingRuntime` allows the app to support multiple inference engines
/// (llama.cpp and MLX) without leaking backend-specific logic into
/// the `RuntimeManager` or higher-level services.
///
/// Thread-safety note: `activeBackend` is mutated only through `load()` and
/// `unload()`. In practice all callers go through `RuntimeManager` which is
/// `@MainActor`, serialising access. A future migration to `actor` would make
/// this invariant explicit.
final class RoutingRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "router"

    private let llamaCpp: LlamaCppRuntime
    private let mlx: MLXRuntime

    private let log = Logger(subsystem: "HomeHub", category: "RoutingRuntime")

    /// The currently active backend.
    private var activeBackend: (any LocalLLMRuntime)?

    var loadedModel: LocalModel? { activeBackend?.loadedModel }

    /// Telemetry is aggregated from the currently active backend.
    var telemetry: RuntimeTelemetry { activeBackend?.telemetry ?? .noOp }

    init(llamaCpp: LlamaCppRuntime, mlx: MLXRuntime) {
        self.llamaCpp = llamaCpp
        self.mlx = mlx
    }

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
        let targetBackend: any LocalLLMRuntime = switch model.backend {
        case .llamaCpp: llamaCpp
        case .mlx:      mlx
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
