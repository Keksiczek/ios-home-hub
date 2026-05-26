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

    /// Semantically-recalled snippets from earlier turns the budgeter
    /// trimmed out of `recentMessages`. Each entry is the *content* of
    /// a past message that scored similar to the current user input.
    /// `PromptAssemblyService` renders these as an "Earlier in this
    /// conversation, you said:" block so the user can ask follow-ups
    /// to specific old turns without needing them pinned as facts.
    ///
    /// Distinct from `conversationSummary`:
    ///   - `conversationSummary` is a single paragraph paraphrasing the
    ///     older half — loses specific wording.
    ///   - `conversationRecall` preserves verbatim text of a few
    ///     hand-picked old turns chosen by semantic similarity to
    ///     the current query.
    /// They cooperate: summary gives context, recall gives precision.
    var conversationRecall: [String] = []
    /// Text extracted from attached documents in the current turn.
    var fileExcerpts: [String] = []
    /// Raw image bytes from photo attachments on the current user turn.
    /// Populated by `ConversationService` from `Message.Attachment.imageData`
    /// when the active model's `ModelCapabilityProfile.supportsVision` is
    /// `true`. Empty otherwise — text-only models would gain nothing from
    /// the bytes and the prompt-assembly path skips the copy.
    ///
    /// `PromptAssemblyService` attaches these to the final user
    /// `RuntimeMessage` so the runtime (once the MLX-VLM path is wired)
    /// can hand them straight to `VLMModelFactory`.
    var userImages: [Data] = []
    /// Instructions derived from active skills to be injected into the system prompt.
    var skillInstructions: String? = nil
    /// Names of tools (skills) actually available for this turn — the
    /// intersection of what `SkillManager` has registered and what
    /// `AppSettings.enabledTools` allows. Drives the Tool-policy block in
    /// the context rail and the conditional wording of the privacy rail.
    var availableTools: Set<String> = []
    /// Compact `UserMemory` block — name, location, notes, preferences.
    /// When non-nil, `PromptAssemblyService` injects it as a dedicated
    /// section so small models see the user's own curated facts on
    /// every turn regardless of what the retrieval heuristics surface.
    var userMemoryBlock: String? = nil
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
