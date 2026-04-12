import Foundation

/// Abstraction over a local on-device LLM backend.
///
/// The whole rest of the app talks to this protocol via
/// `RuntimeManager`. The protocol is intentionally minimal: load,
/// unload, stream tokens, and observe telemetry. Anything richer
/// (chat templates, tool calls, KV cache reuse, structured output)
/// belongs in concrete implementations or higher-level services so we
/// keep the runtime surface tiny and swappable.
///
/// V1 ships with `LlamaCppRuntime`. `MockLocalRuntime` is used by
/// previews and tests. A future `MLXRuntime` can be added without
/// touching anything above this layer.
protocol LocalLLMRuntime: AnyObject, Sendable {
    /// Stable identifier for diagnostics ("llama.cpp", "mlx", "mock").
    var identifier: String { get }

    /// Last-known loaded model.
    ///
    /// **Consistency guarantee**: reflects the state after the most recent
    /// `load()` or `unload()` call completed. Not authoritative for callers
    /// in other concurrency domains — reads may observe a stale value during
    /// the brief window between actor commit and mirror update.
    ///
    /// **Rule of thumb**: use `loadedModel` for UI gating and
    /// "is anything loaded?" guards. For guaranteed-consistent reads before
    /// starting a generation, prefer the concrete runtime's
    /// `currentModel() async` if available.
    var loadedModel: LocalModel? { get }

    /// Structured telemetry channel for this runtime instance.
    ///
    /// Subscribe with `telemetry.subscribe()` to receive an
    /// `AsyncStream<RuntimeTelemetryEvent>` covering load times, first-token
    /// latency, tokens/sec, cancellation, and memory-pressure events.
    ///
    /// Default implementation returns `RuntimeTelemetry.noOp` (events
    /// discarded); override in production runtimes.
    var telemetry: RuntimeTelemetry { get }

    /// Loads a model into memory. Throws on failure. Cancels any active
    /// generation before loading. Implementations are expected to honour
    /// memory pressure and unload on backgrounding.
    func load(model: LocalModel) async throws

    /// Tears down the loaded model and frees memory. In-flight generations
    /// receive a `.finished(.cancelled)` event before the C++ context is freed.
    func unload() async

    /// Streams generation events for the given prompt. The returned stream
    /// finishes with a `.finished(...)` event (followed by stream termination)
    /// or throws on error. Cancelling the consumer `Task` cancels generation.
    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error>
}

// MARK: - Default telemetry

extension LocalLLMRuntime {
    /// Default: no-op telemetry. `MockLocalRuntime` and test stubs inherit
    /// this so they don't need to implement the property.
    var telemetry: RuntimeTelemetry { .noOp }
}

// MARK: - Supporting types

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
        case .noModelLoaded:            return "No model is currently loaded."
        case .modelNotInstalled:        return "This model isn't installed yet."
        case .outOfMemory:              return "The device ran out of memory while loading the model."
        case .incompatibleModel(let m): return "This model isn't compatible with the runtime: \(m)"
        case .cancelled:                return "Generation was cancelled."
        case .underlying(let m):        return m
        }
    }
}
