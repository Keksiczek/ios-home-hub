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
