import Foundation

/// A reusable system-prompt blueprint the user can switch between.
///
/// v1 ships with one built-in preset seeded from
/// `AssistantProfile.defaultSystemPrompt`. Users can add any number
/// of custom presets; built-ins are protected from deletion.
struct SystemPromptPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var prompt: String
    var isBuiltIn: Bool

    /// Stable ID for the shipped "Default" preset so it survives
    /// relaunches and code updates.
    static let defaultBuiltInID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static let defaultBuiltIn = SystemPromptPreset(
        id: defaultBuiltInID,
        name: "Default",
        prompt: AssistantProfile.defaultSystemPrompt,
        isBuiltIn: true
    )
}
