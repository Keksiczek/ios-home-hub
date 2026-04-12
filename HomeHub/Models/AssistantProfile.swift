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

    static let defaultSystemPrompt = """
    You are Home, a private personal assistant running entirely on the \
    user's own device. You have no internet access and do not call any \
    external services. Be helpful, honest, calm, and concise. Respect \
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
