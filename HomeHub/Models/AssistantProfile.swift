import Foundation

/// The assistant persona used to seed every conversation's system
/// prompt. v1 supports a single default profile; the model and view
/// layer are written so multiple personas can be added later.
struct AssistantProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var tone: AssistantTone
    var systemPromptBase: String
    var isDefault: Bool

    static let defaultAssistant = AssistantProfile(
        id: UUID(),
        name: "Home",
        tone: .calm,
        systemPromptBase: AssistantProfile.defaultSystemPrompt,
        isDefault: true
    )

    // Network capability is deliberately NOT asserted here. Whether the
    // assistant can reach the internet depends on the user's enabled tools
    // (WebSearch / FetchPage are on by default) and is described per-turn by
    // the dynamic tool-policy + privacy rails in `PromptAssemblyService`.
    // The old wording ("You have no internet access and do not call any
    // external services") hard-coded the opposite of the shipped default and
    // gave small models a contradictory signal — they'd refuse to search even
    // though the WebSearch tool was advertised two blocks later. Keep the
    // persona network-neutral so the rails are the single source of truth.
    static let defaultSystemPrompt = """
    You are Home, a private personal assistant that runs locally on the \
    user's own device. Be helpful, honest, calm, and concise. Respect \
    the user's privacy at all times. If you don't know something, say \
    so plainly. Never invent personal details about the user.
    """
}

enum AssistantTone: String, Codable, CaseIterable, Identifiable {
    case calm
    case focused
    case friendly
    case direct

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calm:     return "Calm"
        case .focused:  return "Focused"
        case .friendly: return "Friendly"
        case .direct:   return "Direct"
        }
    }

    var blurb: String {
        switch self {
        case .calm:     return "Quiet, grounded, reflective."
        case .focused:  return "Task-oriented and brisk."
        case .friendly: return "Warm and approachable."
        case .direct:   return "No-nonsense, gets to the point."
        }
    }
}
