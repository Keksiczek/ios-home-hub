import Foundation
import SwiftUI

/// Represents an AI Assistant Persona with a specific role, icon, and system prompt.
public struct Persona: Identifiable, Equatable, Hashable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let icon: String
    public let color: Color
    public let systemPrompt: String
    public let shortDescription: String

    public init(id: String, name: String, icon: String, color: Color, systemPrompt: String, shortDescription: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.systemPrompt = systemPrompt
        self.shortDescription = shortDescription
    }

    /// Default system-wide persona library
    public static let library: [Persona] = [
        Persona(
            id: "default_assistant",
            name: "Univerzální",
            icon: "sparkles",
            color: .blue,
            systemPrompt: "Jsi inteligentní a ochotný AI asistent. Tvé odpovědi jsou stručné, přesné a přátelské.",
            shortDescription: "Všestranný pomocník pro každý den."
        ),
        Persona(
            id: "developer",
            name: "Programátor",
            icon: "chevron.left.forwardslash.chevron.right",
            color: .purple,
            systemPrompt: "Jsi expert na vývoj softwaru. Odpovídej výhradně pomocí čistého a funkčního kódu s minimem zbytečného textu. Vždy používej markdown pro formátování kódu.",
            shortDescription: "Specialista na psaní čistého kódu."
        ),
        Persona(
            id: "copywriter",
            name: "Kreativec",
            icon: "paintbrush.pointed.fill",
            color: .orange,
            systemPrompt: "Jsi kreativní copywriter. Tvé texty jsou poutavé, originální a mají skvělý flow. Používej bohatou slovní zásobu a občas i vhodné emoji.",
            shortDescription: "Mistr poutavých textů a e-mailů."
        ),
        Persona(
            id: "translator",
            name: "Překladatel",
            icon: "character.book.closed.fill",
            color: .green,
            systemPrompt: "Jsi profesionální překladatel a jazykový korektor. Tvojí úlohou je perfektně přeložit poskytnutý text nebo opravit gramatiku, a to bez jakéhokoliv dalšího vysvětlování (pokud si ho uživatel výslovně nevyžádá).",
            shortDescription: "Překlady a gramatika bez zbytečných řečí."
        )
    ]
}
