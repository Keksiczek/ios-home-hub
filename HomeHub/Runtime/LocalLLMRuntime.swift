import Foundation

/// Abstraction over a local on-device LLM backend.
///
/// The whole rest of the app talks to this protocol via
/// `RuntimeManager`. The protocol is intentionally minimal: load,
/// unload, and stream tokens. Anything richer (chat templates, tool
/// calls, KV cache reuse, structured output) belongs in concrete
/// implementations or higher-level services so we keep the runtime
/// surface tiny and swappable.
///
/// V1 ships with `LlamaCppRuntime`. `MockLocalRuntime` is used by
/// previews and tests. A future `MLXRuntime` can be added without
/// touching anything above this layer.
protocol LocalLLMRuntime: AnyObject, Sendable {
    /// Stable identifier for diagnostics ("llama.cpp", "mlx", "mock").
    var identifier: String { get }

    /// Currently loaded model, if any.
    var loadedModel: LocalModel? { get }

    /// Loads a model into memory. Throws on failure. Cancels any
    /// existing load. Implementations are expected to honor
    /// memory pressure and unload on backgrounding.
    func load(model: LocalModel) async throws

    /// Tears down the loaded model and frees memory.
    func unload() async

    /// Streams generation events for the given prompt. The returned
    /// stream finishes either with a `.finished(...)` event followed
    /// by stream termination, or by throwing on error. Cancelling
    /// the consumer Task cancels the underlying generation.
    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error>
}

struct RuntimePrompt: Sendable {
    var systemPrompt: String
    var messages: [RuntimeMessage]
}

struct RuntimeMessage: Sendable {
    enum Role: Sendable { case system, user, assistant }
    let role: Role
    let content: String
}

struct RuntimeParameters: Sendable {
    var maxTokens: Int
    var temperature: Double
    var topP: Double
    var stopSequences: [String]

    static let balanced = RuntimeParameters(
        maxTokens: 768,
        temperature: 0.7,
        topP: 0.9,
        stopSequences: []
    )
}

enum RuntimeEvent: Sendable {
    case token(String)
    case finished(reason: FinishReason, stats: RuntimeStats)

    enum FinishReason: Sendable {
        case stop
        case length
        case cancelled
        case error
    }
}

struct RuntimeStats: Sendable {
    var tokensGenerated: Int
    var tokensPerSecond: Double
    var totalDurationMs: Int
}

enum RuntimeError: LocalizedError {
    case noModelLoaded
    case modelNotInstalled
    case outOfMemory
    case incompatibleModel(String)
    case cancelled
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:           return "No model is currently loaded."
        case .modelNotInstalled:       return "This model isn't installed yet."
        case .outOfMemory:             return "The device ran out of memory while loading the model."
        case .incompatibleModel(let m): return "This model isn't compatible with the runtime: \(m)"
        case .cancelled:               return "Generation was cancelled."
        case .underlying(let m):       return m
        }
    }
}
