import Foundation

/// Method used to extract a memory item from conversation.
enum ExtractionMethod: String, Codable, Hashable {
    case heuristic
    case structured
}

/// A compact summary of a meaningful user episode — ongoing work,
/// stated goals, decisions, or important developments. Episodes are
/// shorter-lived than facts and optimized for retrieval into prompts.
///
/// Every episode retains provenance back to the source conversation
/// and message so users can audit where information came from and the
/// system can reprocess if needed.
struct MemoryEpisode: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var summary: String
    var sourceConversationID: UUID
    var sourceMessageID: UUID
    var createdAt: Date
    var lastRelevantAt: Date?
    var approved: Bool
    var disabled: Bool
    var extractionMethod: ExtractionMethod
}
