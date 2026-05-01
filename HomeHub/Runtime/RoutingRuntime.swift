import Foundation
import os


/// Dispatches calls to the appropriate backend based on model metadata.
///
/// `RoutingRuntime` allows the app to support multiple inference engines
/// (llama.cpp and MLX) without leaking backend-specific logic into
/// the `RuntimeManager` or higher-level services.
final class RoutingRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "router"
    
    private let llamaCpp: LlamaCppRuntime
    private let mlx: MLXRuntime
    
    /// The currently active backend.
    private var activeBackend: (any LocalLLMRuntime)?
    
    var loadedModel: LocalModel? { activeBackend?.loadedModel }
    
    /// Telemetry is aggregated from the currently active backend.
    var telemetry: RuntimeTelemetry { activeBackend?.telemetry ?? .noOp }
    
    init(llamaCpp: LlamaCppRuntime, mlx: MLXRuntime) {
        self.llamaCpp = llamaCpp
        self.mlx = mlx
    }
    
    func load(model: LocalModel) async throws {
        // 1. Pick the correct backend
        let targetBackend: any LocalLLMRuntime = switch model.backend {
        case .llamaCpp: llamaCpp
        case .mlx:      mlx
        }
        
        let logger = Logger(subsystem: "HomeHub", category: "RoutingRuntime")
        logger.info("RoutingRuntime: Routing model '\(model.id, privacy: .public)' to backend '\(targetBackend.identifier, privacy: .public)'")
        
        // 2. If we are switching backends, unload the old one first
        if let current = activeBackend, current !== targetBackend {
            await current.unload()
        }
        
        activeBackend = targetBackend
        
        // 3. Forward the load call
        try await targetBackend.load(model: model)
    }
    
    func unload() async {
        await activeBackend?.unload()
        activeBackend = nil
    }
    
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
