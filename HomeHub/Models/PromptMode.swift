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
    /// Chat and tool-followup use the caller-supplied `settings`; the
    /// other modes override temperature and max-tokens for deterministic,
    /// tightly-scoped output.
    func defaultParameters(
        settings: AppSettings,
        stopSequences: [String] = []
    ) -> RuntimeParameters {
        switch self {
        case .chat, .toolFollowup:
            return RuntimeParameters(
                maxTokens: settings.maxResponseTokens,
                temperature: settings.temperature,
                topP: settings.topP,
                stopSequences: stopSequences
            )
        case .summarization:
            return RuntimeParameters(
                maxTokens: 200,
                temperature: 0.2,
                topP: 0.9,
                stopSequences: stopSequences
            )
        case .memoryExtraction:
            return RuntimeParameters(
                maxTokens: 384,
                temperature: 0.1,
                topP: 0.9,
                stopSequences: []
            )
        }
    }
}
