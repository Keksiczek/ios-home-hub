import Foundation

/// A persisted chat thread between the user and a single assistant
/// profile. Messages are stored separately and loaded lazily by id.
struct Conversation: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var title: String
    var assistantProfileID: UUID
    var modelID: String
    var createdAt: Date
    var updatedAt: Date
    var lastMessagePreview: String?
    var pinned: Bool
    var archived: Bool

    static func new(assistantID: UUID, modelID: String, title: String = "New chat") -> Conversation {
        Conversation(
            id: UUID(),
            title: title,
            assistantProfileID: assistantID,
            modelID: modelID,
            createdAt: .now,
            updatedAt: .now,
            lastMessagePreview: nil,
            pinned: false,
            archived: false
        )
    }
}

/// Compact, text-only summary of a conversation. Optional v1 feature
/// — generated lazily once a conversation grows beyond a threshold
/// to keep prompt context budgets in check.
struct ConversationSummary: Codable, Equatable {
    let conversationID: UUID
    var summary: String
    var coversMessageIDs: [UUID]
    var generatedAt: Date
}
