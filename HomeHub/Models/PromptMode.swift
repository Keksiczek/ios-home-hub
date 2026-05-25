import Foundation

/// Identifies the purpose of an inference call so `PromptAssemblyService`
/// can select the right system prompt layers, token budget, and generation
/// parameters for each use case.
///
/// Before this enum existed, every inference call — chat replies,
/// summarisation, memory extraction, tool follow-ups — shared the same
/// monolithic 7-layer prompt and the user's global temperature/topP.
/// The result was wasted context budget (extraction doesn't need facts or
/// episodes) and suboptimal parameters (summarisation benefits from T=0.2,
/// not the user's creative T=0.7).
///
/// ## Adding a new mode
/// 1. Add the case here.
/// 2. Provide a `defaultParameters` branch.
/// 3. Add a branch in `PromptAssemblyService.assembleSystemPrompt(for:from:)`.
/// 4. Write a test in `PromptModeAssemblyTests`.
enum PromptMode: String, Sendable, Hashable, CaseIterable {

    /// Normal conversational reply. Full 7-layer system prompt including
    /// persona, user profile, facts, episodes, file excerpts, and skill
    /// instructions. Uses the user's global settings for temperature and
    /// max tokens.
    case chat

    /// Second (or later) iteration of the agentic tool loop. The model
    /// has already emitted an `<Action:…>` tag, the skill has executed,
    /// and the observation is appended to the message history. The system
    /// prompt is identical to `.chat` but skill instructions are trimmed
    /// to a short reminder ("use the observation to answer") so the
    /// model doesn't waste tokens re-reading tool descriptions.
    case toolFollowup

    /// Background inference pass that condenses older conversation turns
    /// into a short summary. Tight token budget (200), low temperature
    /// (0.2), no memory layers, no skill instructions.
    case summarization

    /// Background inference pass that extracts durable facts and episodic
    /// summaries from a user message. Tight budget (384), very low
    /// temperature (0.1), strict JSON-only instruction. No user profile,
    /// no history, no skill instructions.
    case memoryExtraction

    /// Returns the `RuntimeParameters` appropriate for this mode.
    ///
    /// Sampling precedence:
    ///   1. If the user has customised any sampling field in Settings
    ///      (detected by comparing against `AppSettings.factorySampling`),
    ///      their values win — power users keep control.
    ///   2. Otherwise the loaded model's `ModelCapabilityProfile`
    ///      provides vendor-recommended values per family. This is
    ///      critical for small models — Gemma 3n needs temp 0.4 +
    ///      repetition_penalty 1.2 to stay on-language, while Qwen 2.5
    ///      wants temp 0.7 + top_k 20. Sharing the cross-family default
    ///      of temp 0.7 / no repetition penalty caused Gemma replies to
    ///      drift into mixed-language gibberish in the field.
    ///   3. Tool-followup forces near-deterministic sampling (temp 0.1)
    ///      regardless — the model is just rendering an observation,
    ///      not being creative.
    func defaultParameters(
        settings: AppSettings,
        profile: ModelCapabilityProfile? = nil,
        stopSequences: [String] = []
    ) -> RuntimeParameters {
        switch self {
        case .chat:
            let s = Self.resolvedSampling(settings: settings, profile: profile)
            // Dynamic maxTokens cap.
            //
            // **Always honour user intent first.** If the slider was
            // moved off factory, return it verbatim — power users tuning
            // long-form replies must not be silently overridden.
            //
            // **Profile-derived ceiling.** When the user is on the
            // factory baseline, cap at `profile.generationReserveTokens`.
            // That value is already calibrated per family / device tier
            // (`ModelCapabilityProfile.dynamicHistoryBudget` could be
            // extended to scale it; today it's a static per-family hint
            // — 512 for chat-tuned small models, larger for code models
            // when those land). The factory `maxResponseTokens = 768`
            // is the "I haven't thought about it" ceiling — we trade
            // 256 of those for guaranteed prefill headroom on small-
            // memory tiers without ever forcing a hard limit on users
            // who actually want a long reply.
            //
            // This replaces a prior hardcoded `min(maxResponseTokens, 512)
            // when isWeak`; the dynamic form scales with whatever the
            // profile knows (Gemma 3n reserves 512, a future 70B chat
            // profile could reserve 2048) instead of carrying a magic
            // number in this file.
            let userOverrode = settings.maxResponseTokens != AppSettings.factorySampling.maxResponseTokens
            let maxTokens: Int
            if userOverrode {
                maxTokens = settings.maxResponseTokens
            } else if let profile {
                maxTokens = min(settings.maxResponseTokens, profile.generationReserveTokens)
            } else {
                maxTokens = settings.maxResponseTokens
            }
            return RuntimeParameters(
                maxTokens: maxTokens,
                temperature: s.temperature,
                topP: s.topP,
                stopSequences: stopSequences,
                topK: s.topK,
                minP: s.minP,
                repeatPenalty: s.repeatPenalty,
                repeatPenaltyLastN: s.repeatPenaltyLastN
            )
        case .toolFollowup:
            // Deterministic: the model has the observation in context
            // and just needs to render it. Creative sampling produced
            // hallucinated outputs ("Takových 2 stupňů" appearing
            // alongside a real calculator result). Keep top_p high so
            // we don't constrain phrasing, but drop temperature low
            // enough that the answer is essentially argmax over the
            // top tokens.
            return RuntimeParameters(
                maxTokens: settings.maxResponseTokens,
                temperature: 0.1,
                topP: 0.95,
                stopSequences: stopSequences,
                topK: 20,
                minP: 0.0,
                repeatPenalty: profile?.recommendedRepeatPenalty ?? 1.05,
                repeatPenaltyLastN: 64
            )
        case .summarization:
            // Tight, deterministic parameters; we still want a touch of repeat
            // penalty so summaries don't loop on a single phrase.
            return RuntimeParameters(
                maxTokens: 200,
                temperature: 0.2,
                topP: 0.9,
                stopSequences: stopSequences,
                topK: 40,
                minP: 0.05,
                repeatPenalty: 1.1,
                repeatPenaltyLastN: 64
            )
        case .memoryExtraction:
            // Strict JSON output. Disable repeat penalty so legitimately
            // repeating field names (`"content":`, `"confidence":`) survive.
            return RuntimeParameters(
                maxTokens: 384,
                temperature: 0.1,
                topP: 0.9,
                stopSequences: [],
                topK: 40,
                minP: 0.0,
                repeatPenalty: 1.0,
                repeatPenaltyLastN: 0
            )
        }
    }

    /// Compact bag of the six sampling knobs we route to the runtime.
    /// Kept private because it only exists to make the precedence rules
    /// in `resolvedSampling` readable.
    private struct ResolvedSampling {
        let temperature: Double
        let topP: Double
        let topK: Int
        let minP: Double
        let repeatPenalty: Double
        let repeatPenaltyLastN: Int
    }

    /// Picks family-recommended sampling when the user is on the
    /// factory defaults, user-customised sampling otherwise. The
    /// detection uses field-by-field equality against
    /// `AppSettings.factorySampling` — that way someone who tweaked
    /// just the temperature still keeps their tweak while the
    /// remaining fields can pick up family recommendations they
    /// never explicitly chose.
    private static func resolvedSampling(
        settings: AppSettings,
        profile: ModelCapabilityProfile?
    ) -> ResolvedSampling {
        guard let profile else {
            return ResolvedSampling(
                temperature: settings.temperature,
                topP: settings.topP,
                topK: settings.topK,
                minP: settings.minP,
                repeatPenalty: settings.repeatPenalty,
                repeatPenaltyLastN: settings.repeatPenaltyLastN
            )
        }
        let f = AppSettings.factorySampling
        // User opt-in: when `gemma3nTightSamplingOverride` is on AND the
        // resolved profile is the Gemma 3n one, the per-family
        // "recommended" picks are replaced by the historical tight
        // stack — only for sliders the user hasn't manually moved.
        // Mirrors the auto-pick semantics for every other family:
        // touched sliders win, untouched sliders take the family
        // override. Lets a user pin the pre-2026-05 sampling without
        // resetting their other tweaks.
        let isGemma3n = profile.family == ModelCapabilityProfile.gemma3n.family
            && profile.recommendedRepeatPenaltyLastN == ModelCapabilityProfile.gemma3n.recommendedRepeatPenaltyLastN
        let useTight = settings.gemma3nTightSamplingOverride && isGemma3n
        let tight = ModelCapabilityProfile.gemma3nTightSampling
        let pickTemp        = useTight ? tight.temperature        : profile.recommendedTemperature
        let pickTopP        = useTight ? tight.topP               : profile.recommendedTopP
        let pickTopK        = useTight ? tight.topK               : profile.recommendedTopK
        let pickMinP        = useTight ? tight.minP               : profile.recommendedMinP
        let pickRepPenalty  = useTight ? tight.repeatPenalty      : profile.recommendedRepeatPenalty
        let pickRepWindow   = useTight ? tight.repeatPenaltyLastN : profile.recommendedRepeatPenaltyLastN
        return ResolvedSampling(
            temperature:        settings.temperature        == f.temperature        ? pickTemp       : settings.temperature,
            topP:               settings.topP               == f.topP               ? pickTopP       : settings.topP,
            topK:               settings.topK               == f.topK               ? pickTopK       : settings.topK,
            minP:               settings.minP               == f.minP               ? pickMinP       : settings.minP,
            repeatPenalty:      settings.repeatPenalty      == f.repeatPenalty      ? pickRepPenalty : settings.repeatPenalty,
            repeatPenaltyLastN: settings.repeatPenaltyLastN == f.repeatPenaltyLastN ? pickRepWindow  : settings.repeatPenaltyLastN
        )
    }
}
