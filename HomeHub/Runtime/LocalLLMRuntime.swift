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

    /// Extended load with optional phase-reporting callback.
    ///
    /// Two-phase semantics:
    /// - `.downloading(fraction:)` — real fractional progress while weights are
    ///   fetched from Hugging Face Hub. Not emitted for warm-cache loads.
    /// - `.preparing` — download complete; weights are being mapped into memory
    ///   and the Metal compute pipeline is being compiled (~10–60 s on iPhone).
    ///   No fraction is available for this phase.
    ///
    /// Default implementation: delegates to `load(model:)` without emitting
    /// any phase events. Override in backends that support real progress
    /// (currently `MLXRuntime`).
    func loadWithProgress(
        model: LocalModel,
        progressHandler: (@Sendable (MLXLoadPhase) -> Void)?
    ) async throws

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

    /// Called when the OS delivers a memory-pressure notification.
    ///
    /// Implementations should respect their own unload policy and unload
    /// the model if appropriate. Default: no-op (used by `MockLocalRuntime`
    /// and test stubs; the real implementation is in `LlamaCppRuntime`).
    func handleMemoryPressure() async

    /// Called when the app scene moves to the background.
    ///
    /// Implementations should unload the model if their policy requires it.
    /// Default: no-op (used by `MockLocalRuntime` and test stubs).
    func handleBackground() async

    /// Removes any cached state or session for the given conversation.
    /// No-op if the runtime doesn't support session persistence.
    func invalidateSession(for conversationID: UUID) async
}

// MARK: - Default implementations

extension LocalLLMRuntime {
    /// Default: no-op telemetry. `MockLocalRuntime` and test stubs inherit
    /// this so they don't need to implement the property.
    var telemetry: RuntimeTelemetry { .noOp }

    /// Default: delegates to `load(model:)` without emitting phase events.
    /// Overridden by `MLXRuntime` for real Hub download progress.
    func loadWithProgress(
        model: LocalModel,
        progressHandler: (@Sendable (MLXLoadPhase) -> Void)?
    ) async throws {
        try await load(model: model)
    }

    /// Default: no-op. Overridden by `LlamaCppRuntime`.
    func handleMemoryPressure() async {}

    /// Default: no-op. Overridden by `LlamaCppRuntime`.
    func handleBackground() async {}

    /// Default: no-op.
    func invalidateSession(for conversationID: UUID) async {}
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
    /// Top-K cutoff. `0` disables the sampler. Small values (20–60) cut the
    /// long tail of low-probability tokens that drive most "weird character"
    /// and broken-Czech artifacts on small (≤ 4B) models.
    var topK: Int = 40
    /// Minimum-probability cutoff for nucleus sampling. Tokens whose
    /// probability is below `minP × p_max` are dropped before sampling.
    /// `0.0` disables the sampler. 0.05 is a sensible default that
    /// suppresses garbage tokens without hurting creativity.
    var minP: Double = 0.05
    /// Repetition penalty over the last `repeatPenaltyLastN` tokens.
    /// `1.0` disables it. 1.1 is the de-facto llama.cpp default and the
    /// single biggest fix for "the model keeps repeating itself" on small
    /// models.
    var repeatPenalty: Double = 1.1
    /// How many of the most recent tokens the repeat penalty applies to.
    /// `0` disables it (treated as no penalty).
    var repeatPenaltyLastN: Int = 64
    /// Frequency penalty (OpenAI-style; subtracted from logits proportional
    /// to occurrence count). `0.0` disables. Tiny values (0.0–0.2) further
    /// reduce loops without hurting fluency.
    var frequencyPenalty: Double = 0.0
    /// Presence penalty (OpenAI-style; flat penalty if token has appeared
    /// at all in the last window). `0.0` disables.
    var presencePenalty: Double = 0.0
    /// Conversation the generation belongs to.
    /// When set, `LlamaCppRuntime` attempts KV-cache prefix reuse across turns.
    var conversationID: UUID?

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
    case initializationFailed(String)
    case cancelled
    case generationInProgress
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:              return "No model is currently loaded."
        case .modelNotInstalled:          return "This model isn't installed yet."
        case .outOfMemory:               return "The device ran out of memory while loading the model."
        case .incompatibleModel(let m):  return "This model isn't compatible with the runtime: \(m)"
        case .initializationFailed(let m): return "Model initialization failed: \(m)"
        case .cancelled:                 return "Generation was cancelled."
        case .underlying(let m):         return m
        }
    }
}
