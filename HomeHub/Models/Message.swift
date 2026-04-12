import Foundation

struct Message: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let conversationID: UUID
    var role: Role
    var content: String
    var createdAt: Date
    var status: Status
    var tokenCount: Int?
    var attachments: [Attachment]?

    struct Attachment: Codable, Equatable, Hashable, Identifiable {
        let id: UUID
        let filename: String
        let extractedText: String
    }

    enum Role: String, Codable, Hashable {
        case system
        case user
        case assistant
    }

    enum Status: String, Codable, Hashable {
        case pending
        case streaming
        case complete
        case failed
        case cancelled
    }

    static func user(_ text: String, in conversationID: UUID, attachments: [Attachment]? = nil) -> Message {
        Message(
            id: UUID(),
            conversationID: conversationID,
            role: .user,
            content: text,
            createdAt: .now,
            status: .complete,
            tokenCount: nil,
            attachments: attachments
        )
    }

    static func assistantPlaceholder(in conversationID: UUID) -> Message {
        Message(
            id: UUID(),
            conversationID: conversationID,
            role: .assistant,
            content: "",
            createdAt: .now,
            status: .streaming,
            tokenCount: nil,
            attachments: nil
        )
    }
}
