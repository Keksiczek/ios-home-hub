import Foundation

/// Abstraction over a local on-device LLM backend.
///
/// The rest of the app talks to this protocol via `RuntimeManager`. The
/// surface is intentionally minimal: load, unload, stream tokens, observe
/// telemetry. Anything richer (chat templates, tool calls, KV-cache reuse,
/// structured output) belongs in concrete implementations or higher-level
/// services so the runtime surface stays small and swappable.
///
/// **Concrete runtimes:**
/// - `MLXRuntime` — primary backend; always available.
/// - `LlamaCppRuntime` — secondary, opt-in via `HOMEHUB_LLAMA_RUNTIME`.
/// - `RoutingRuntime` — dispatches by `LocalModel.backend`.
/// - `MockLocalRuntime` — previews and tests.
protocol LocalLLMRuntime: AnyObject, Sendable {
    /// Stable identifier for diagnostics ("mlx", "llama.cpp", "router", "mock").
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
    /// and test stubs; `MLXRuntime` and `LlamaCppRuntime` override).
    func handleMemoryPressure() async

    /// Soft tier of memory-pressure response — release **cheap** caches
    /// (KV reuse session, sampler / template scratch) without dropping
    /// model weights. Called on the first L1 warning in a debounce window
    /// before the hard `handleMemoryPressure()` path is considered.
    /// Default: no-op.
    func trimMemoryCaches() async

    /// `true` while a generation task is producing tokens. Used by the
    /// two-tier pressure policy to defer hard unload until the current
    /// turn finishes (interrupting a streaming reply is worse UX than
    /// finishing it and unloading immediately after).
    /// Default: `false` (runtimes without active-generation tracking).
    var isCurrentlyGenerating: Bool { get }

    /// Called when the app scene moves to the background.
    ///
    /// Implementations should unload the model if their policy requires it.
    /// Default: no-op (used by `MockLocalRuntime` and test stubs).
    func handleBackground() async

    /// Removes any cached state or session for the given conversation.
    /// No-op if the runtime doesn't support session persistence.
    func invalidateSession(for conversationID: UUID) async

    /// Most recent user-facing generation failure, or `nil` if the last
    /// generation succeeded (or nothing has run yet). Backend-agnostic
    /// surface consumed by `ModelInfoSheet` and `DeveloperDiagnostics`.
    var lastGenerationError: GenerationFailure? { get }

    /// Conversation ID whose KV-cache session is currently warm inside
    /// the runtime, or `nil` when nothing is cached. Used by the chat
    /// developer strip to surface "Reuse cache: ANO/NE" for the active
    /// conversation. **Read-only** — modifying cache state is the
    /// runtime's responsibility, not the UI's.
    ///
    /// Default implementation: `nil` (mock / minimal runtimes that
    /// don't track sessions). Concrete runtimes override.
    var activeSessionConversationID: UUID? { get }

    /// Rolling-average tokens/sec for `modelID`, or `nil` if the runtime
    /// doesn't track throughput. Read by diagnostics only.
    func averageThroughput(for modelID: String) -> (tps: Double, samples: Int)?

    /// Snapshot of the throughput distribution: median (p50) and tail
    /// (p95). p50 catches typical performance; p95 surfaces the
    /// worst-case stalls that a mean-only readout hides (a model with
    /// mean 30 t/s and p95-of-2 t/s is functionally unusable even
    /// though the mean looks fine). `nil` if the runtime doesn't
    /// track per-sample history.
    func throughputPercentiles(for modelID: String) -> (p50: Double, p95: Double, samples: Int)?

    /// Real BPE token count for `text` using the active model's
    /// tokenizer. Returns `nil` when no model is loaded or when the
    /// runtime doesn't expose a tokenizer (mock / fake runtimes).
    ///
    /// **Cost.** Asynchronous because the underlying MLX container is
    /// an actor — calling its tokenizer requires hopping through
    /// `container.perform`. Not safe to call per-streaming-token; the
    /// heuristic estimator in `PromptTokenBudgeter` covers the hot
    /// path. Use this method for:
    ///   - Per-turn budget calibration (compare heuristic vs real)
    ///   - Diagnostics ("show me the ground truth token count")
    ///   - Test fixtures that need real numbers
    ///
    /// Default implementation: `nil`. `MLXRuntime` overrides.
    func realTokenCount(of text: String) async -> Int?
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

    /// Default: no-op. Overridden by runtimes that auto-unload on pressure.
    func handleMemoryPressure() async {}

    /// Default: no-op. Overridden by runtimes that drop scratch buffers
    /// on L1 warnings (MLX clears its `ChatSession` + KV reuse cache).
    func trimMemoryCaches() async {}

    /// Default: `false`. Concrete runtimes that track generation state
    /// (MLX, llama.cpp) override.
    var isCurrentlyGenerating: Bool { false }

    /// Default: no-op. Overridden by runtimes that unload on background.
    func handleBackground() async {}

    /// Default: no-op.
    func invalidateSession(for conversationID: UUID) async {}

    /// Default: runtime does not record failures. Concrete runtimes
    /// (MLX, llama.cpp) override.
    var lastGenerationError: GenerationFailure? { nil }

    /// Default: runtime doesn't track cached sessions (mock / preview).
    /// `MLXRuntime` overrides with the active `ActiveSession.conversationID`.
    var activeSessionConversationID: UUID? { nil }

    /// Default: no throughput tracking. Concrete runtimes override.
    func averageThroughput(for modelID: String) -> (tps: Double, samples: Int)? { nil }

    /// Default: no per-sample history. `MLXRuntime` overrides.
    func throughputPercentiles(for modelID: String) -> (p50: Double, p95: Double, samples: Int)? { nil }

    /// Default: no real-tokenizer access (mock / preview / non-MLX).
    /// `MLXRuntime` overrides by routing through `container.perform`.
    func realTokenCount(of text: String) async -> Int? { nil }
}

// MARK: - Supporting types

struct RuntimePrompt: Sendable {
    /// Full assembled system prompt (stable + volatile concatenated).
    /// Backward-compat surface — concrete runtimes today still consume
    /// this single string. Computed from the split fields below so
    /// callers that only set `systemPrompt` directly still work.
    var systemPrompt: String {
        get {
            if stableSystemPrompt.isEmpty { return volatileSystemPrompt }
            if volatileSystemPrompt.isEmpty { return stableSystemPrompt }
            return stableSystemPrompt + "\n\n" + volatileSystemPrompt
        }
        set {
            // Legacy callers (tests, previews) that assign to
            // `systemPrompt` directly: treat the whole string as
            // stable. Volatile is empty — we can't safely split a
            // pre-joined string without re-parsing.
            stableSystemPrompt = newValue
            volatileSystemPrompt = ""
        }
    }

    /// **Stable** part of the system prompt — persona, language
    /// policy, style block, hard rules. Identical across every turn
    /// of a conversation. Surface designed so a future MLX
    /// `ChatSession` hook can pin this prefix in the KV cache and
    /// skip re-tokenization for turns where only the volatile half
    /// changes.
    var stableSystemPrompt: String = ""

    /// **Volatile** part of the system prompt — retrieved facts,
    /// episodes, recall snippets, file excerpts, skill instructions,
    /// current date/time. Recomputed every turn so it's never a cache
    /// hit candidate. Kept separate from the stable prefix so the
    /// diagnostic budget report can show how much of the total is
    /// cacheable vs. churn.
    var volatileSystemPrompt: String = ""

    var messages: [RuntimeMessage]

    init(systemPrompt: String, messages: [RuntimeMessage]) {
        self.messages = messages
        // Use the setter so the split fields get populated.
        self.systemPrompt = systemPrompt
    }

    init(
        stableSystemPrompt: String,
        volatileSystemPrompt: String,
        messages: [RuntimeMessage]
    ) {
        self.stableSystemPrompt = stableSystemPrompt
        self.volatileSystemPrompt = volatileSystemPrompt
        self.messages = messages
    }
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

    /// When `true`, the runtime MUST rebuild generation state from scratch
    /// (a fresh `ChatSession` for MLX, no `llama_kv_cache_clear` skip for
    /// llama.cpp) rather than reusing a cached prefix. Use this to bypass
    /// the entire KV-cache reuse logic when:
    ///   - Investigating multi-turn "garbage output" regressions, or
    ///   - The caller wants a single-turn-style inference that's known to
    ///     be insulated from any formatting discrepancy in the history
    ///     (the "stateless pipeline" from the architectural blueprint).
    ///
    /// **Interaction with `ChatTemplate`:** stateless mode does not change
    /// templating. The MLX path still passes `prompt.messages.dropLast()`
    /// as the session history; we just construct a brand-new session for
    /// every turn instead of reusing the one keyed on `conversationID`.
    /// The llama.cpp path uses the same `ChatTemplate.render` output it
    /// always does — the only difference is that the cached prefix
    /// comparison in `LlamaRuntimeActor` is short-circuited to "no match".
    ///
    /// Default `false` — current behaviour. No UI toggle yet; flip in
    /// code or via `RuntimeParameters(.balanced + forceStateless: true)`
    /// for experiments.
    var forceStateless: Bool = false

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
    /// Soft, non-fatal signal. The watchdog uses it to surface
    /// "model has been silent for N seconds" without cancelling the
    /// generation. UI may show a banner or do nothing; consumers MUST
    /// tolerate zero or many `.warning` events per generation.
    case warning(RuntimeWarning)

    enum FinishReason: Sendable {
        case stop
        case length
        case cancelled
        case error
    }
}

/// Structured non-fatal signals emitted alongside tokens. Carries a
/// machine-readable kind + a localised user message so the UI can
/// localise or skip kinds it doesn't care about (vs. parsing free
/// text).
struct RuntimeWarning: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        /// No tokens have arrived for the threshold window. Fires at
        /// 30 s, 60 s, 120 s; consumer may show a "model is taking
        /// longer than usual" banner.
        case generationStall
    }
    let kind: Kind
    let message: String
    /// Time since the last token (or generation start), seconds.
    let secondsSilent: Int
}

struct RuntimeStats: Sendable {
    var tokensGenerated: Int
    var tokensPerSecond: Double
    var totalDurationMs: Int
}

enum RuntimeError: LocalizedError, Equatable {
    case noModelLoaded
    case modelNotInstalled
    case outOfMemory
    case incompatibleModel(String)
    case initializationFailed(String)
    case cancelled
    case generationInProgress
    /// The model targets a backend that isn't linked into this build.
    /// Carries the model's display name so the UI can be specific.
    case backendUnavailable(modelName: String, backend: ModelBackend)
    /// Required files missing from the on-disk model cache. `missing`
    /// contains a short human list ("config.json, tokenizer files");
    /// surfaced verbatim in the Model Info sheet and in load failure
    /// notifications, so it must be free of low-level symbols.
    case missingFiles(modelName: String, missing: [String])
    /// On-disk cache directory exists but isn't a recognisable MLX model
    /// (no `config.json`, no weights, or both — already classified as
    /// such by `LocalModelService.inspectMLXCache`).
    case invalidModelDirectory(modelName: String, detail: String)
    /// Catch-all for unsupported model configurations (vocab mismatch,
    /// architecture not implemented by mlx-swift-lm, tokenizer the
    /// bridge can't load). The carried `detail` is intentionally raw —
    /// the surrounding UI wraps it with context.
    case unsupportedModelConfiguration(String)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No model is currently loaded."
        case .modelNotInstalled:
            return "This model isn't installed yet."
        case .outOfMemory:
            return "The device ran out of memory while loading the model."
        case .incompatibleModel(let m):
            return "This model isn't compatible with the runtime: \(m)"
        case .initializationFailed(let m):
            return "Model initialization failed: \(m)"
        case .cancelled:
            return "Generation was cancelled."
        case .generationInProgress:
            return "Another generation is already in progress. Cancel it before starting a new one."
        case .backendUnavailable(let name, let backend):
            switch backend {
            case .llamaCpp:
                return "\"\(name)\" je GGUF / llama.cpp model. Tento build podporuje pouze MLX. " +
                       "Pro načtení GGUF modelu zapni HOMEHUB_LLAMA_RUNTIME a přidej llama.xcframework. " +
                       "Viz README → \"Optional: llama.cpp opt-in\"."
            case .mlx:
                return "\"\(name)\" vyžaduje MLX runtime, který není v tomto buildu k dispozici. " +
                       "(Pravděpodobně chyba v build configu — MLX má být vždy přítomný.)"
            }
        case .missingFiles(let name, let missing):
            let list = missing.isEmpty ? "required files" : missing.joined(separator: ", ")
            return "Model \"\(name)\" je neúplný na disku — chybí \(list). Smaž ho a stáhni znovu."
        case .invalidModelDirectory(let name, let detail):
            return "Model \"\(name)\" nelze načíst: \(detail)"
        case .unsupportedModelConfiguration(let m):
            return "Model nelze načíst kvůli nepodporované konfiguraci: \(m)"
        case .underlying(let m):
            return m
        }
    }
}
