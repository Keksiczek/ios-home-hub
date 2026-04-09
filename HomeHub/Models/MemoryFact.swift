import Foundation

/// A piece of long-term, user-controlled context the assistant can
/// reference. Distinct from chat history. The user can add, edit,
/// pin, disable, and delete facts at any time from the Memory tab.
struct MemoryFact: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var content: String
    var category: Category
    var source: Source
    var confidence: Double
    var createdAt: Date
    var lastUsedAt: Date?
    var pinned: Bool
    var disabled: Bool

    enum Category: String, Codable, CaseIterable, Hashable, Identifiable {
        case personal
        case work
        case preferences
        case relationships
        case projects
        case other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .personal:      return "Personal"
            case .work:          return "Work"
            case .preferences:   return "Preferences"
            case .relationships: return "Relationships"
            case .projects:      return "Projects"
            case .other:         return "Other"
            }
        }

        var symbol: String {
            switch self {
            case .personal:      return "person"
            case .work:          return "briefcase"
            case .preferences:   return "heart"
            case .relationships: return "person.2"
            case .projects:      return "folder"
            case .other:         return "tag"
            }
        }
    }

    enum Source: String, Codable, Hashable {
        case onboarding
        case userManual
        case conversationExtraction
    }
}

/// A fact that has been *proposed* by the extraction service but not
/// yet accepted by the user. Surfaced as cards in the Memory tab.
struct MemoryCandidate: Identifiable, Equatable, Hashable {
    let id: UUID
    var content: String
    var category: MemoryFact.Category
    var sourceConversationID: UUID
    var sourceMessageID: UUID
    var proposedAt: Date
}
