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

    var icon: String?
    var colorHex: String?
    var shortDescription: String?

    /// Stable ID for the shipped "Default" preset so it survives
    /// relaunches and code updates.
    static let defaultBuiltInID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let developerBuiltInID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let copywriterBuiltInID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let translatorBuiltInID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    static let defaultBuiltIn = SystemPromptPreset(
        id: defaultBuiltInID,
        name: "Univerzální",
        prompt: AssistantProfile.defaultSystemPrompt,
        isBuiltIn: true,
        icon: "sparkles",
        colorHex: "007AFF", // Blue
        shortDescription: "Všestranný asistent pro každý den."
    )
    
    static let developerBuiltIn = SystemPromptPreset(
        id: developerBuiltInID,
        name: "Programátor",
        prompt: "Jsi expert na vývoj softwaru. Odpovídej výhradně pomocí čistého a funkčního kódu s minimem zbytečného textu. Vždy používej markdown pro formátování kódu.",
        isBuiltIn: true,
        icon: "chevron.left.forwardslash.chevron.right",
        colorHex: "AF52DE", // Purple
        shortDescription: "Specialista na psaní čistého kódu."
    )
    
    static let copywriterBuiltIn = SystemPromptPreset(
        id: copywriterBuiltInID,
        name: "Kreativec",
        prompt: "Jsi kreativní copywriter. Tvé texty jsou poutavé, originální a mají skvělý flow. Používej bohatou slovní zásobu a občas i vhodné emoji.",
        isBuiltIn: true,
        icon: "paintbrush.pointed.fill",
        colorHex: "FF9500", // Orange
        shortDescription: "Mistr poutavých textů a e-mailů."
    )

    static let translatorBuiltIn = SystemPromptPreset(
        id: translatorBuiltInID,
        name: "Překladatel",
        prompt: "Jsi profesionální překladatel a jazykový korektor. Tvojí úlohou je perfektně přeložit poskytnutý text nebo opravit gramatiku, a to bez jakéhokoliv dalšího vysvětlování (pokud si ho uživatel výslovně nevyžádá).",
        isBuiltIn: true,
        icon: "character.book.closed.fill",
        colorHex: "34C759", // Green
        shortDescription: "Překlady a gramatika bez řečí."
    )
    
    static let builtIns: [SystemPromptPreset] = [
        defaultBuiltIn, developerBuiltIn, copywriterBuiltIn, translatorBuiltIn
    ]
}
