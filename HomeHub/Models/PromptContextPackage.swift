import Foundation

/// Everything that goes into the next inference call, in one bag.
///
/// Created by `ConversationService.send(...)` and consumed by
/// `PromptAssemblyService.build(...)`. Splitting this from the raw
/// `RuntimePrompt` keeps personalization concerns out of the runtime
/// layer and lets us swap prompt formats without touching domain
/// logic.
struct PromptContextPackage {
    var assistant: AssistantProfile
    var user: UserProfile
    var facts: [MemoryFact]
    var episodes: [MemoryEpisode]
    var recentMessages: [Message]
    var userInput: String
    var settings: AppSettings
    /// Condensed summary of messages older than the history window.
    /// Set by `ConversationService` when the context budget is > 60% used
    /// and there are messages outside the 20-message window. Injected into
    /// the system prompt so older context isn't silently dropped.
    var conversationSummary: String? = nil
    /// Text extracted from attached documents in the current turn.
    var fileExcerpts: [String] = []
    /// Instructions derived from active skills to be injected into the system prompt.
    var skillInstructions: String? = nil
    /// Capability profile for the model that will process this prompt.
    ///
    /// Used by `PromptAssemblyService` to apply per-family token budgets and
    /// by future prompt-mode logic (EPIC 5) to shape sections for specific
    /// model families. Defaults to `ModelCapabilityProfile.default` when nil
    /// (e.g. in previews and unit tests that don't specify a model).
    var modelCapabilityProfile: ModelCapabilityProfile? = nil

    /// Which prompt shape to use for this inference call.
    ///
    /// Determines which system-prompt layers are included and what
    /// `RuntimeParameters` are appropriate. Defaults to `.chat` so
    /// existing call sites that don't specify a mode get the full
    /// conversational prompt.
    var promptMode: PromptMode = .chat
}

/// A snapshot of the user's personalization state at a point in
/// time. Useful for diffing what the assistant "knows" before vs.
/// after an onboarding edit, and for the upcoming "review what I
/// remember" screen.
struct PersonalizationSnapshot: Equatable {
    var user: UserProfile
    var assistant: AssistantProfile
    var enabledFacts: [MemoryFact]
    var capturedAt: Date
}
