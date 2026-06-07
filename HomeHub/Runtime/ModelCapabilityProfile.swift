import Foundation

/// Static capability and parameter profile for a model family.
///
/// Centralises every model-specific constant that was previously scattered
/// across `LlamaContextHandle`, `PromptAssemblyService`, and ad-hoc
/// conditionals. Adding support for a new model family means adding one
/// entry here; nothing else in the call stack needs to change.
///
/// ## Usage
/// ```swift
/// let profile = ModelCapabilityProfile.resolve(family: model.family)
/// // In LlamaContextHandle.load():
/// ctxParams.flash_attn = profile.supportsFlashAttention
/// ctxParams.n_ubatch   = UInt32(profile.nUBatch)
/// // In PromptTokenBudgeter:
/// let budgeter = PromptTokenBudgeter(profile: profile)
/// ```
///
/// ## Future fields (stubs — not yet consumed)
/// - `supportsStructuredToolCalling`: EPIC 3 will use this to enable
///   grammar-constrained output for families that support it.
/// - `prefersDeferredMemoryExtraction`: EPIC 4 will use this to schedule
///   heavy extraction only for models where it's cost-effective.
struct ModelCapabilityProfile: Sendable, Equatable {

    // MARK: - Identity

    /// Canonical lowercase family name (e.g. `"llama"`, `"phi"`, `"qwen"`).
    let family: String

    // MARK: - llama.cpp parameters (consumed by LlamaContextHandle only)
    //
    // The MLX backend ignores everything in this section — `MLXLLM.ChatSession`
    // owns its own attention / batch / KV-cache settings. Kept here so the
    // opt-in llama.cpp path stays a one-flag flip without per-family rework.

    /// Whether flash attention is safe for this family.
    ///
    /// Phi-3/4 and some quantised models have known correctness issues with
    /// `flash_attn = true`; all others default to `true` for throughput.
    let supportsFlashAttention: Bool

    /// Micro-batch size for token-by-token generation (`n_ubatch`).
    ///
    /// Base value; actual runtime value is overridden by DeviceMemoryProvider.
    /// This field is deprecated in favor of dynamic allocation per device tier.
    /// Kept for backward compatibility only.
    @available(*, deprecated, message: "Use DeviceMemoryProvider.shared.profile.microBatchSizeTokens")
    let nUBatch: Int

    // MARK: - Prompt budget (consumed by PromptTokenBudgeter)

    /// Maximum number of tokens reserved for conversation history in the
    /// assembled prompt.
    ///
    /// Budget rationale for a typical 4096-token context:
    ///   system prompt  ≈ 400–600 tokens
    ///   generation      =   512 tokens (reserved)
    ///   ─────────────────────────────────
    ///   available        ≈ 3000 tokens
    ///   safe history     ≤ this value (headroom for tool instructions etc.)
    let safeHistoryTokenBudget: Int

    /// Tokens reserved for the model's generation output.
    ///
    /// The prompt guard in `LlamaContextHandle` uses this value when computing
    /// the 90%-of-n_ctx safety limit. `PromptBudgetReport` includes it so
    /// diagnostics can verify prompt + reserve stays under the context length.
    let generationReserveTokens: Int

    /// Extra tokens added per chat message by the model's chat template.
    ///
    /// Chat templates wrap each turn in family-specific delimiter tokens
    /// (header IDs, role markers, end-of-turn tokens). These overhead
    /// tokens accumulate in long conversations and must be accounted for
    /// to avoid underestimating prompt size.
    ///
    /// Calibrated values per family (approximate, measured against the
    /// shared BPE tokenizer vocabulary used by both runtimes):
    /// - llama: 7  — `<|start_header_id|>role<|end_header_id|>\n\n…<|eot_id|>`
    /// - qwen:  5  — `<|im_start|>role\n…<|im_end|>\n`
    /// - mistral: 6 — `[INST] … [/INST]` (instruction variant)
    /// - gemma: 6  — `<start_of_turn>role\n…<end_of_turn>\n`
    /// - phi:   5  — `<|user|>\n…<|end|>\n`
    /// - default: 5 — conservative fallback
    let messageTokenOverhead: Int

    // MARK: - Future capability flags (stubs for later EPICs)

    /// Whether this family reliably emits structured tool-call JSON
    /// (EPIC 3). Currently unused — all families use the regex-based
    /// action-tag protocol.
    let supportsStructuredToolCalling: Bool

    /// Whether memory extraction should be deferred to a background job
    /// rather than run inline (EPIC 4). Currently unused — policy is set
    /// at the call-site level regardless of model family.
    let prefersDeferredMemoryExtraction: Bool

    /// Whether this model family includes vision-capable variants that
    /// accept image inputs alongside text. Set on the *family* profile —
    /// the catalog still picks which specific repo to download. When
    /// `true`, the chat composer keeps the original image bytes in the
    /// attachment and the runtime forwards them to the model; when
    /// `false` (default) we only ship the OCR'd text as today.
    ///
    /// Concrete vision-capable families (as of 2026-05):
    /// - `gemma-3n` (vision variant)
    /// - `qwen-vl` / `qwen2-vl`
    /// - `smolvlm`
    /// - `llava`
    ///
    /// Pure-text families (`llama`, `phi`, `mistral`, etc.) stay `false`.
    /// When an image is attached on a `supportsVision` model, `MLXRuntime`
    /// routes the turn through the VLM `UserInput` path
    /// (`MLXRuntime.shouldUseVisionInputPath`), which feeds the decoded
    /// image to the model.
    let supportsVision: Bool

    // MARK: - Sampling defaults
    //
    // Family-specific recommended sampling parameters. Applied at model
    // load time (overriding the global `AppSettings` defaults) unless
    // the user has explicitly customised them. Vendor-recommended values
    // dramatically reduce language drift / repetition on small models.

    /// Recommended temperature for this family.
    let recommendedTemperature: Double

    /// Recommended top-p (nucleus) for this family.
    let recommendedTopP: Double

    /// Recommended top-k for this family. `0` = disabled.
    let recommendedTopK: Int

    /// Recommended min-p threshold. `0.0` = disabled.
    let recommendedMinP: Double

    /// Recommended repetition penalty. `1.0` = none, `>1` penalises.
    /// Critical for Gemma family which has strong repetition bias.
    let recommendedRepeatPenalty: Double

    /// Window over which repetition penalty is computed.
    let recommendedRepeatPenaltyLastN: Int

    // MARK: - Instruction-following tier
    //
    // True for small / quantised models that lose coherence on long
    // multi-section system prompts. When set, `PromptAssemblyService`
    // emits a leaner chat prompt: drops the hard-rules block,
    // verbatim conversation recall, file excerpts, and episodes;
    // tightens memory-fact / recall caps. Persona, tone, profile,
    // facts (capped), tool instructions, and language policy stay —
    // they're load-bearing.
    //
    // Concrete targets: Gemma 3n (4B active), Phi-3 Mini (3.8B),
    // anything <= 3B. The full L1-L7 stack is 1500-2500 tokens for
    // these models which alone eats 30-50% of a 4k context and
    // demonstrably correlates with the mode collapse / language
    // bleed we saw in the field.
    let isWeakInstructionFollower: Bool

    /// Explicit init so existing static profiles (`.llama`, `.qwen`, …)
    /// don't need a memberwise-init churn every time we add a new
    /// capability flag. `supportsVision` defaults to `false` because
    /// every currently-shipped family is text-only; vision-capable
    /// variants will opt in by name in their own static profile.
    init(
        family: String,
        supportsFlashAttention: Bool,
        nUBatch: Int,
        safeHistoryTokenBudget: Int,
        generationReserveTokens: Int,
        messageTokenOverhead: Int,
        supportsStructuredToolCalling: Bool,
        prefersDeferredMemoryExtraction: Bool,
        recommendedTemperature: Double,
        recommendedTopP: Double,
        recommendedTopK: Int,
        recommendedMinP: Double,
        recommendedRepeatPenalty: Double,
        recommendedRepeatPenaltyLastN: Int,
        isWeakInstructionFollower: Bool,
        supportsVision: Bool = false
    ) {
        self.family = family
        self.supportsFlashAttention = supportsFlashAttention
        self.nUBatch = nUBatch
        self.safeHistoryTokenBudget = safeHistoryTokenBudget
        self.generationReserveTokens = generationReserveTokens
        self.messageTokenOverhead = messageTokenOverhead
        self.supportsStructuredToolCalling = supportsStructuredToolCalling
        self.prefersDeferredMemoryExtraction = prefersDeferredMemoryExtraction
        self.recommendedTemperature = recommendedTemperature
        self.recommendedTopP = recommendedTopP
        self.recommendedTopK = recommendedTopK
        self.recommendedMinP = recommendedMinP
        self.recommendedRepeatPenalty = recommendedRepeatPenalty
        self.recommendedRepeatPenaltyLastN = recommendedRepeatPenaltyLastN
        self.isWeakInstructionFollower = isWeakInstructionFollower
        self.supportsVision = supportsVision
    }
}

// MARK: - Built-in profiles

extension ModelCapabilityProfile {

    // MARK: Per-family constants

    /// Llama 3.x, 3.1, 3.2, 3.3 — large context, flash-attn safe.
    /// Sampling: Meta's official recommendation is temp 0.6 / topP 0.9
    /// with mild repetition penalty for short-context replies.
    static let llama = ModelCapabilityProfile(
        family: "llama",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1400,
        generationReserveTokens: 1024,
        messageTokenOverhead: 7,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false,
        recommendedTemperature: 0.6,
        recommendedTopP: 0.9,
        recommendedTopK: 50,
        recommendedMinP: 0.05,
        recommendedRepeatPenalty: 1.1,
        recommendedRepeatPenaltyLastN: 64,
        isWeakInstructionFollower: false
    )

    /// Qwen 1.5, 2, 2.5 — flash-attn safe, ChatML template.
    /// Sampling: Alibaba's official Qwen 2.5 card recommends
    /// temp 0.7 / topK 20 / topP 0.8 / repetitionPenalty 1.05.
    static let qwen = ModelCapabilityProfile(
        family: "qwen",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1400,
        generationReserveTokens: 1024,
        messageTokenOverhead: 5,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false,
        recommendedTemperature: 0.7,
        recommendedTopP: 0.8,
        recommendedTopK: 20,
        recommendedMinP: 0.0,
        recommendedRepeatPenalty: 1.05,
        recommendedRepeatPenaltyLastN: 64,
        isWeakInstructionFollower: false
    )

    /// Mistral 7B and Mixtral variants. Moderate sampling pressure.
    static let mistral = ModelCapabilityProfile(
        family: "mistral",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1400,
        generationReserveTokens: 1024,
        messageTokenOverhead: 6,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false,
        recommendedTemperature: 0.7,
        recommendedTopP: 0.9,
        recommendedTopK: 40,
        recommendedMinP: 0.0,
        recommendedRepeatPenalty: 1.1,
        recommendedRepeatPenaltyLastN: 64,
        isWeakInstructionFollower: false
    )

    /// Gemma 1, 2 — verbose turn tokens consume extra context budget.
    /// Sampling: Gemma family has strong repetition bias; raise the
    /// repetition penalty above the cross-family default and tighten
    /// nucleus to keep low-prob foreign-language tokens out.
    static let gemma = ModelCapabilityProfile(
        family: "gemma",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1200,
        generationReserveTokens: 1024,
        messageTokenOverhead: 6,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false,
        recommendedTemperature: 0.5,
        recommendedTopP: 0.9,
        recommendedTopK: 40,
        recommendedMinP: 0.05,
        recommendedRepeatPenalty: 1.15,
        recommendedRepeatPenaltyLastN: 64,
        // Gemma 2 2B variant is borderline-weak but the 9B is fine.
        // Tag the family conservatively as not weak; users running 2B
        // can downgrade by picking the `default` profile via manual
        // family override (no UI for that yet — accepted trade-off).
        isWeakInstructionFollower: false
    )

    /// Gemma 3n — MatFormer architecture, 8B params but ~4B active during inference.
    /// Revolutionary efficiency: larger model quality with small model VRAM footprint.
    ///
    /// **Sampling rationale** (re-tuned 2026-05 toward Google's published
    /// defaults). Earlier revisions clamped `temperature` to 0.35-0.40 to
    /// suppress a foreign-language drift seen on Q4 MLX quants — Czech
    /// replies bleeding Russian / Spanish tokens. That drift was the
    /// dominant defect at the time and the tight stack was correct for
    /// that build. Two things changed:
    ///
    ///   1. The drift root cause was traced to a sampler bug in
    ///      mlx-swift-lm that ignored `repeatPenalty` / `minP` /
    ///      `topK`; we now pass the full stack through
    ///      (`MLXRuntime.generate`). Repetition pressure + min-p alone
    ///      do most of the work the temperature clamp used to do.
    ///   2. With `temperature 0.40` the model produced flat, repetitive
    ///      answers — the field complaint shifted from "drifts into
    ///      other languages" to "boring / says the same thing twice".
    ///
    /// New baseline: `temperature 0.7` (midpoint between the old clamp
    /// and Google's `1.0` model-card default), `topK 64` (matches
    /// model card), `minP 0.08` and `repeatPenalty 1.25 / window 192`
    /// retained — those are the levers that suppress the residual drift
    /// without flattening the distribution. A user-visible toggle in
    /// Settings → Sampling lets users restore the historical tight
    /// values if their device / quant exhibits the old drift.
    ///
    /// **History budget 1600** — kept. Empirically, Gemma 3n quality
    /// degrades on prompts > ~1700 effective tokens (counting chat-
    /// template overhead) even though its trained context is 32k+.
    /// Trading budget for stability.
    static let gemma3n = ModelCapabilityProfile(
        family: "gemma",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1600,
        generationReserveTokens: 1024,
        messageTokenOverhead: 6,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false,
        recommendedTemperature: 0.7,
        recommendedTopP: 0.9,
        recommendedTopK: 64,
        recommendedMinP: 0.08,
        recommendedRepeatPenalty: 1.25,
        recommendedRepeatPenaltyLastN: 192,
        // Gemma 3n's ~4B active params + per-layer-skipping make it
        // visibly degrade on long multi-section prompts. Lean mode on.
        isWeakInstructionFollower: true
    )

    /// Pre-2026-05 Gemma 3n sampling stack — preserved so the
    /// `gemma3nTightSamplingOverride` user toggle has a stable reference
    /// to fall back to. These values were originally tuned against early
    /// Q4 quants exhibiting foreign-language token drift; the new
    /// `gemma3n.recommended*` baseline is looser because the underlying
    /// sampler bug was fixed and the drift no longer reproduces on the
    /// current mlx-swift-lm builds. If a user reports the old drift on
    /// a specific device / quant, flipping the toggle restores this
    /// stack without a rebuild.
    static let gemma3nTightSampling: (
        temperature: Double,
        topP: Double,
        topK: Int,
        minP: Double,
        repeatPenalty: Double,
        repeatPenaltyLastN: Int
    ) = (
        temperature: 0.40,
        topP: 0.9,
        topK: 32,
        minP: 0.08,
        repeatPenalty: 1.25,
        repeatPenaltyLastN: 192
    )

    /// Phi-3 Mini/Medium and Phi-4 — flash_attn = true causes incorrect
    /// output on at least some quantised checkpoints; keep it off.
    /// Sampling: Phi-3 docs recommend moderate temperature; the
    /// quantised checkpoints repeat without a penalty.
    /// RepeatPenalty 1.2 / window 128 — field evidence shows Phi-3 Mini
    /// (3.8B, always isWeak) loops at 1.1/64; 1.2/128 stops it.
    static let phi = ModelCapabilityProfile(
        family: "phi",
        supportsFlashAttention: false,
        nUBatch: 64,
        safeHistoryTokenBudget: 1200,
        generationReserveTokens: 1024,
        messageTokenOverhead: 5,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false,
        recommendedTemperature: 0.5,
        recommendedTopP: 0.9,
        recommendedTopK: 40,
        recommendedMinP: 0.05,
        recommendedRepeatPenalty: 1.2,
        recommendedRepeatPenaltyLastN: 128,
        // Phi-3 Mini (3.8B) is small enough that the L1-L7 stack
        // overwhelms it. Phi-4 (14B) doesn't have the issue but we
        // can't distinguish them by family string alone; lean mode
        // is the safer default for everything on the phi branch.
        isWeakInstructionFollower: true
    )

    /// SmolLM2 — Hugging Face's small (135M / 360M / 1.7B) on-device
    /// chat models, ChatML template. All sizes ship at ≤ 2B params so
    /// the family is universally weak; sampling is tightened to match
    /// the gemma3n / phi-3-mini calibration that proved necessary for
    /// small Q4 models in the field (cross-language drift, repetition
    /// loops under default 1.1/64 penalty).
    static let smolLM2 = ModelCapabilityProfile(
        family: "smollm2",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1000,
        generationReserveTokens: 768,
        messageTokenOverhead: 5,            // ChatML — same as Qwen
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false,
        recommendedTemperature: 0.4,        // tight; small model + Q4
        recommendedTopP: 0.9,
        recommendedTopK: 40,
        recommendedMinP: 0.08,
        recommendedRepeatPenalty: 1.2,
        recommendedRepeatPenaltyLastN: 128,
        // All released SmolLM2 sizes are 1.7B or smaller — weak by
        // construction, lean mode on.
        isWeakInstructionFollower: true
    )

    /// SmolVLM — HuggingFace's small Vision-Language Model
    /// (256M / 500M / 2B variants). Multimodal: accepts images +
    /// text. Image input is mandatory for the vision path to fire;
    /// when no image is attached the chat runs as a normal text turn.
    /// When an image IS attached, `MLXRuntime` routes the turn through
    /// the VLM `UserInput` path (`shouldUseVisionInputPath`), which
    /// feeds the decoded image to the model; `supportsVision: true`
    /// is the gate that selects that path.
    ///
    /// Sampling mirrors SmolLM2 (same base architecture) but with
    /// a slightly looser temperature because the vision-conditioned
    /// distribution is naturally more peaked.
    static let smolVLM = ModelCapabilityProfile(
        family: "smolvlm",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1000,
        generationReserveTokens: 768,
        messageTokenOverhead: 5,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false,
        recommendedTemperature: 0.5,
        recommendedTopP: 0.9,
        recommendedTopK: 40,
        recommendedMinP: 0.08,
        recommendedRepeatPenalty: 1.2,
        recommendedRepeatPenaltyLastN: 128,
        isWeakInstructionFollower: true,
        supportsVision: true
    )

    /// Qwen2-VL family — Alibaba's vision-language variant of
    /// Qwen2. Available in 2B and 7B sizes. The 2B fits on
    /// iPhone 15 Pro+, the 7B is iPad-only at Q4. Sampling is
    /// inherited from Qwen but `supportsVision` is the gate
    /// that activates the image-tensor pathway.
    static let qwenVL = ModelCapabilityProfile(
        family: "qwen-vl",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1400,
        generationReserveTokens: 1024,
        messageTokenOverhead: 5,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false,
        recommendedTemperature: 0.7,
        recommendedTopP: 0.8,
        recommendedTopK: 20,
        recommendedMinP: 0.0,
        recommendedRepeatPenalty: 1.05,
        recommendedRepeatPenaltyLastN: 64,
        isWeakInstructionFollower: false,
        supportsVision: true
    )

    /// Fallback for unknown or user-supplied families.
    ///
    /// Most conservative settings: no flash attention, smallest history
    /// budget. A model that doesn't match any known family is most likely
    /// experimental; err on the safe side.
    /// RepeatPenalty 1.2 / window 128 — unknown/small models (SmolLM2,
    /// custom imports) have the same repetition tendency as Phi-3 Mini.
    static let `default` = ModelCapabilityProfile(
        family: "",
        supportsFlashAttention: false,
        nUBatch: 64,
        safeHistoryTokenBudget: 1000,
        generationReserveTokens: 512,
        messageTokenOverhead: 5,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false,
        recommendedTemperature: 0.7,
        recommendedTopP: 0.9,
        recommendedTopK: 40,
        recommendedMinP: 0.05,
        recommendedRepeatPenalty: 1.2,
        recommendedRepeatPenaltyLastN: 128,
        // Unknown family → conservative: assume weak. Users running
        // a large unknown model can override by tagging the family
        // string correctly in the catalog.
        isWeakInstructionFollower: true
    )

    // MARK: - Resolution

    /// Returns the capability profile for the given model-family string.
    ///
    /// Matching is case-insensitive substring search so that strings like
    /// `"llama3"`, `"Llama-3.2-3B"`, and `"meta-llama"` all resolve to
    /// the Llama profile. The first match wins; the ordering below
    /// prioritises specificity (e.g. `"phi"` before the default).
    ///
    /// - Parameter family: `LocalModel.family` as stored in the catalog.
    static func resolve(family: String) -> ModelCapabilityProfile {
        resolve(family: family, parameterCount: nil)
    }

    /// Size-aware overload. Promotes small variants of "strong" families
    /// to `isWeakInstructionFollower = true` and tightens sampling.
    ///
    /// Llama 3.2 1B is the canonical case: family `"llama"` resolves to
    /// `.llama` (not weak, temp 0.6, repeat 1.1) but in the field the 1B
    /// at Q4 catastrophically fails on the full multi-section prompt:
    /// parrots context as its opening line, mixes languages (English /
    /// Russian tokens bleed into Czech replies), hallucinates entities.
    /// Treat anything ≤ 2B as weak regardless of family.
    ///
    /// Additionally, any model with a context window ≤ 2 048 tokens is
    /// promoted to weak regardless of parameter count. The full chat system
    /// prompt (persona + user profile + facts + hard rules + tool policy)
    /// consumes 1 500–2 000 tokens, leaving almost no room for conversation
    /// history on a 2 048-token context. Llama 3.2 3B is the canonical
    /// example: 3B > 2B threshold so it was treated as strong, but its
    /// 2 048-token context caused it to fill with the system prompt on turn 2
    /// and hallucinate names/fragments from the user-memory block.
    ///
    /// - Parameters:
    ///   - family: `LocalModel.family`.
    ///   - parameterCount: `LocalModel.parameterCount` (e.g. `"1B"`, `"3B"`,
    ///     `"8B"`). When `nil`, behaves identically to `resolve(family:)`.
    ///   - contextLength: `LocalModel.contextLength`. When ≤ 2 048 the model
    ///     is promoted to weak regardless of parameter count.
    static func resolve(
        family: String,
        parameterCount: String?,
        contextLength: Int? = nil
    ) -> ModelCapabilityProfile {
        let baseProfile = Self.baseProfile(for: family)
        let adjustedBudget = Self.dynamicHistoryBudget(baseProfile: baseProfile)
        let isSmall = Self.isSmallVariant(parameterCount: parameterCount, contextLength: contextLength)
        let promotedWeak = baseProfile.isWeakInstructionFollower || isSmall

        // For small variants of otherwise-strong families: also tighten
        // sampling (lower temp, harder repetition penalty, wider penalty
        // window, smaller minP floor). Mirrors what gemma3n does for the
        // same reason. phi/default already have 1.2/128 in their base
        // profiles so the max() is a no-op for those; this path matters
        // for e.g. Llama 3.2 1B (strong base, small variant).
        let isSmallOfStrong = isSmall && !baseProfile.isWeakInstructionFollower
        let temp = isSmallOfStrong
            ? min(baseProfile.recommendedTemperature, 0.5)
            : baseProfile.recommendedTemperature
        let repeatPenalty = isSmallOfStrong
            ? max(baseProfile.recommendedRepeatPenalty, 1.2)
            : baseProfile.recommendedRepeatPenalty
        let repeatLastN = isSmallOfStrong
            ? max(baseProfile.recommendedRepeatPenaltyLastN, 128)
            : baseProfile.recommendedRepeatPenaltyLastN
        let minP = isSmallOfStrong
            ? max(baseProfile.recommendedMinP, 0.1)
            : baseProfile.recommendedMinP

        return ModelCapabilityProfile(
            family: baseProfile.family,
            supportsFlashAttention: baseProfile.supportsFlashAttention,
            nUBatch: baseProfile.nUBatch,
            safeHistoryTokenBudget: adjustedBudget,
            generationReserveTokens: baseProfile.generationReserveTokens,
            messageTokenOverhead: baseProfile.messageTokenOverhead,
            supportsStructuredToolCalling: baseProfile.supportsStructuredToolCalling,
            prefersDeferredMemoryExtraction: baseProfile.prefersDeferredMemoryExtraction,
            recommendedTemperature: temp,
            recommendedTopP: baseProfile.recommendedTopP,
            recommendedTopK: baseProfile.recommendedTopK,
            recommendedMinP: minP,
            recommendedRepeatPenalty: repeatPenalty,
            recommendedRepeatPenaltyLastN: repeatLastN,
            isWeakInstructionFollower: promotedWeak,
            supportsVision: baseProfile.supportsVision
        )
    }

    /// Returns `true` when the model should be treated as a weak instruction
    /// follower based on parameter count or context window size.
    ///
    /// Two independent triggers:
    /// - Parameter count ≤ 2B (unchanged).
    /// - Context window ≤ 2 048 tokens: the full system prompt is
    ///   1 500–2 000 tokens, leaving almost nothing for conversation history.
    ///   Llama 3.2 3B (2 048-token context) is the motivating case — it
    ///   was above the 2B threshold but exhibited identical hallucination
    ///   symptoms on the second turn.
    nonisolated static func isSmallVariant(
        parameterCount: String?,
        contextLength: Int? = nil
    ) -> Bool {
        if let ctx = contextLength, ctx <= 2048 { return true }
        guard let raw = parameterCount?.uppercased() else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("M") { return true }
        let body = trimmed.hasSuffix("B") ? String(trimmed.dropLast()) : trimmed
        guard let value = Double(body) else { return false }
        return value <= 2.0
    }

    /// Returns the static (base) profile for the given family.
    /// Used internally by resolve() before dynamic adjustment.
    private static func baseProfile(for family: String) -> ModelCapabilityProfile {
        let f = family.lowercased()
        // Vision-capable families first — they share substrings
        // with their text-only siblings ("qwen-vl" contains "qwen",
        // "smolvlm" contains "smollm"-ish) so order matters.
        if f.contains("qwen-vl") || f.contains("qwen2-vl") { return .qwenVL }
        if f.contains("smolvlm") { return .smolVLM }
        if f.contains("llama")   { return .llama }
        if f.contains("qwen")    { return .qwen }
        if f.contains("mistral") { return .mistral }
        if f.contains("gemma-3n") || f.contains("gemma3n") { return .gemma3n }  // MatFormer: check before generic gemma
        if f.contains("gemma")   { return .gemma }
        if f.contains("phi")     { return .phi }
        if f.contains("smollm")  { return .smolLM2 }
        return .default
    }

    /// Dynamically adjust safeHistoryTokenBudget based on device memory tier.
    ///
    /// Scales the base profile's budget to match available device memory:
    /// - tight (iPhone SE): 50% of base
    /// - moderate (iPhone 13–15): 100% of base (unmodified)
    /// - generous (iPhone 16 Pro): 200% of base (maximize conversation length)
    private static func dynamicHistoryBudget(
        baseProfile: ModelCapabilityProfile
    ) -> Int {
        let memoryProfile = DeviceMemoryProvider.shared.profile
        let base = baseProfile.safeHistoryTokenBudget

        switch memoryProfile.tier {
        case .tight:
            return max(400, Int(Double(base) * 0.5))
        case .moderate:
            // Context doubled from 2048 → 4096; scale budget proportionally.
            return Int(Double(base) * 1.5)
        case .generous:
            return Int(Double(base) * 2.0)
        }
    }
}
