import Foundation
import os

/// Dispatches calls to the appropriate backend based on model metadata.
///
/// `RoutingRuntime` allows the app to support multiple inference engines
/// (MLX is the primary backend; llama.cpp is OPTIONAL and gated behind
/// the `HOMEHUB_LLAMA_RUNTIME` compile flag) without leaking backend-specific
/// logic into the `RuntimeManager` or higher-level services.
///
/// When the flag is OFF (the default), `llamaCpp` is `nil` and any attempt to
/// load a `.llamaCpp` model returns `RuntimeError.incompatibleModel` with a
/// clear message, instead of producing a hard build error.
///
/// Thread-safety note: `activeBackend` is mutated only through `load()` and
/// `unload()`. In practice all callers go through `RuntimeManager` which is
/// `@MainActor`, serialising access. A future migration to `actor` would make
/// this invariant explicit.
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
        let targetBackend: any LocalLLMRuntime
        switch model.backend {
        case .llamaCpp:
            #if HOMEHUB_LLAMA_RUNTIME
            guard let llamaCpp else {
                throw RuntimeError.incompatibleModel(
                    "Model '\(model.displayName)' requires the llama.cpp backend, " +
                    "but it is not currently linked. Rebuild with HOMEHUB_LLAMA_RUNTIME=1 " +
                    "and llama.xcframework on the framework search path, or pick an MLX model."
                )
            }
            targetBackend = llamaCpp
            #else
            throw RuntimeError.incompatibleModel(
                "Model '\(model.displayName)' is a GGUF / llama.cpp model, but this build " +
                "ships with the MLX-only runtime. Rebuild with HOMEHUB_LLAMA_RUNTIME=1, " +
                "or choose an MLX model from the catalog."
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
