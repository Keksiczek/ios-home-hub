import Foundation

/// The end-user's personalization profile.
///
/// Persisted on-device. Captured during onboarding and editable from
/// Settings. The user can wipe this independently of memory facts.
struct UserProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var displayName: String
    var pronouns: String?
    var occupation: String?
    var locale: String
    var interests: [String]
    var workingContext: String?
    var preferredResponseStyle: ResponseStyle
    var createdAt: Date
    var updatedAt: Date

    static let blank = UserProfile(
        id: UUID(),
        displayName: "",
        pronouns: nil,
        occupation: nil,
        locale: Locale.current.identifier,
        interests: [],
        workingContext: nil,
        preferredResponseStyle: .balanced,
        createdAt: .now,
        updatedAt: .now
    )

    var hasMeaningfulContent: Bool {
        !displayName.isEmpty || occupation != nil || !interests.isEmpty || workingContext != nil
    }
}

enum ResponseStyle: String, Codable, CaseIterable, Identifiable {
    case concise
    case balanced
    case warm
    case analytical
    case playful

    var id: String { rawValue }

    var label: String {
        switch self {
        case .concise:    return "Concise"
        case .balanced:   return "Balanced"
        case .warm:       return "Warm"
        case .analytical: return "Analytical"
        case .playful:    return "Playful"
        }
    }

    var blurb: String {
        switch self {
        case .concise:    return "Short, direct answers. No filler."
        case .balanced:   return "A natural mix of clarity and warmth."
        case .warm:       return "Supportive, conversational, human."
        case .analytical: return "Structured, precise, with reasoning."
        case .playful:    return "Light, curious, occasionally witty."
        }
    }
}
