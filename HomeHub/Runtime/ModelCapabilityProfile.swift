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
    var safeHistoryTokenBudget: Int

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
}

// MARK: - Built-in profiles

extension ModelCapabilityProfile {

    // MARK: Per-family constants

    /// Llama 3.x, 3.1, 3.2, 3.3 — large context, flash-attn safe.
    static let llama = ModelCapabilityProfile(
        family: "llama",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1400,
        generationReserveTokens: 512,
        messageTokenOverhead: 7,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false
    )

    /// Qwen 1.5, 2, 2.5 — flash-attn safe, ChatML template.
    static let qwen = ModelCapabilityProfile(
        family: "qwen",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1400,
        generationReserveTokens: 512,
        messageTokenOverhead: 5,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false
    )

    /// Mistral 7B and Mixtral variants.
    static let mistral = ModelCapabilityProfile(
        family: "mistral",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1400,
        generationReserveTokens: 512,
        messageTokenOverhead: 6,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false
    )

    /// Gemma 1, 2 — verbose turn tokens consume extra context budget.
    static let gemma = ModelCapabilityProfile(
        family: "gemma",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1200,
        generationReserveTokens: 512,
        messageTokenOverhead: 6,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false
    )

    /// Gemma 3n — MatFormer architecture, 8B params but ~4B active during inference.
    /// Revolutionary efficiency: larger model quality with small model VRAM footprint.
    static let gemma3n = ModelCapabilityProfile(
        family: "gemma",
        supportsFlashAttention: true,
        nUBatch: 64,
        safeHistoryTokenBudget: 1800,              // More generous: effective 4B active params
        generationReserveTokens: 512,
        messageTokenOverhead: 6,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false
    )

    /// Phi-3 Mini/Medium and Phi-4 — flash_attn = true causes incorrect
    /// output on at least some quantised checkpoints; keep it off.
    static let phi = ModelCapabilityProfile(
        family: "phi",
        supportsFlashAttention: false,
        nUBatch: 64,
        safeHistoryTokenBudget: 1200,
        generationReserveTokens: 512,
        messageTokenOverhead: 5,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false
    )

    /// Fallback for unknown or user-supplied families.
    ///
    /// Most conservative settings: no flash attention, smallest history
    /// budget. A model that doesn't match any known family is most likely
    /// experimental; err on the safe side.
    static let `default` = ModelCapabilityProfile(
        family: "",
        supportsFlashAttention: false,
        nUBatch: 64,
        safeHistoryTokenBudget: 1000,
        generationReserveTokens: 512,
        messageTokenOverhead: 5,
        supportsStructuredToolCalling: false,
        prefersDeferredMemoryExtraction: false
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
        var profile = Self.baseProfile(for: family)
        // Dynamically adjust history budget based on device memory tier.
        profile.safeHistoryTokenBudget = Self.dynamicHistoryBudget(
            baseProfile: profile
        )
        return profile
    }

    /// Returns the static (base) profile for the given family.
    /// Used internally by resolve() before dynamic adjustment.
    private static func baseProfile(for family: String) -> ModelCapabilityProfile {
        let f = family.lowercased()
        if f.contains("llama")   { return .llama }
        if f.contains("qwen")    { return .qwen }
        if f.contains("mistral") { return .mistral }
        if f.contains("gemma-3n") || f.contains("gemma3n") { return .gemma3n }  // MatFormer: check before generic gemma
        if f.contains("gemma")   { return .gemma }
        if f.contains("phi")     { return .phi }
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
            // Conservative: trim history more aggressively
            return max(400, Int(Double(base) * 0.5))
        case .moderate:
            // Keep base budget unchanged
            return base
        case .generous:
            // Generous: allow longer conversation history
            return Int(Double(base) * 2.0)
        }
    }
}
