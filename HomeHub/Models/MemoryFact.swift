import Foundation

/// A piece of long-term, user-controlled context the assistant can
/// reference. Distinct from chat history. The user can add, edit,
/// pin, disable, and delete facts at any time from the Memory tab.
///
/// v2: provenance fields link back to the source conversation/message
/// so users can audit where information came from. These are optional
/// for backward compatibility with v1 persisted data.
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

    // v2 provenance — optional for backward compatibility.
    var sourceConversationID: UUID?
    var sourceMessageID: UUID?
    var extractionMethod: ExtractionMethod?

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

/// A memory item that has been *proposed* by extraction but not yet
/// accepted by the user. Surfaced as cards in the Memory tab.
///
/// v2: candidates can be either durable facts or episodic summaries,
/// distinguished by `kind`. The UI shows both in the same review flow.
struct MemoryCandidate: Identifiable, Equatable, Hashable {
    let id: UUID
    var content: String
    var kind: Kind
    var category: MemoryFact.Category
    var sourceConversationID: UUID
    var sourceMessageID: UUID
    var proposedAt: Date
    var extractionMethod: ExtractionMethod

    enum Kind: String, Hashable {
        case fact
        case episode
    }
}
