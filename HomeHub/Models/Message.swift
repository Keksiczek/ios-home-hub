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
    /// User-set bookmark flag. Optional (with implicit-false read via
    /// `isBookmarked`) so older persisted messages decode without
    /// requiring a migration — Swift's synthesized `Codable` treats a
    /// missing key as `nil` for optionals, but would throw on a
    /// missing non-optional `Bool`.
    var bookmarked: Bool?

    /// Why the runtime stopped generating this message. Stored as a
    /// raw string (not the runtime's enum) so the chat layer doesn't
    /// pull in `MLXLLM` types and so older persisted messages decode
    /// without a migration. Values mirror `RuntimeEvent.FinishReason`:
    /// `"stop"` (model emitted EOT), `"length"` (max tokens budget),
    /// `"cancelled"` (user-initiated stop). `nil` on `.user` /
    /// `.system` messages and on assistant messages persisted before
    /// this field existed.
    ///
    /// Drives the "Pokračovat" affordance: when the value is
    /// `"length"` AND this is the most recent assistant message, the
    /// bubble surfaces a button that asks the model to continue from
    /// where it stopped instead of re-rolling the whole answer.
    var finishReason: String?

    /// Convenience for "is this message bookmarked?" so the UI doesn't
    /// have to repeat the `?? false` defaulting at every call site.
    var isBookmarked: Bool { bookmarked == true }

    /// `true` when the runtime stopped because the max-tokens budget
    /// was reached — i.e. the reply is likely mid-thought. UI uses
    /// this to render the Continue button.
    var wasTruncatedByLength: Bool { finishReason == FinishReasonKey.length }

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

    /// String constants that mirror `RuntimeEvent.FinishReason` cases.
    /// Centralising them here keeps the stringly-typed `finishReason`
    /// comparison sites in sync — a typo would otherwise silently
    /// break `wasTruncatedByLength` without a compiler warning.
    enum FinishReasonKey {
        static let stop      = "stop"
        static let length    = "length"
        static let cancelled = "cancelled"
        static let error     = "error"
    }
}
