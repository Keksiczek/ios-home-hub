import Foundation
import NaturalLanguage

/// Layer 2 of the extraction pipeline: OS-native named-entity extraction
/// via `NLTagger`. Runs in milliseconds with zero model overhead.
///
/// Finds person names, organization names, and place names in a user
/// message and converts each to a `MemoryCandidate`. This fills the gap
/// between the keyword-trigger heuristic (Layer 1) — which only fires on
/// explicit phrases like "I work at" — and the full LLM extraction
/// (Layer 3) — which costs seconds and battery.
///
/// ## Entity → Category mapping
/// | NLTag                | MemoryFact.Category |
/// |----------------------|---------------------|
/// | `.personalName`      | `.relationships`    |
/// | `.organizationName`  | `.work`             |
/// | `.placeName`         | `.personal`         |
enum NLExtractionPass {

    static let minEntityLength = 2

    /// Extracts named entities from `message` and returns one
    /// `MemoryCandidate` per unique entity.
    static func extract(from message: Message) -> [MemoryCandidate] {
        guard message.role == .user else { return [] }
        let text = message.content
        guard text.count >= 3 else { return [] }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var seen = Set<String>()
        var candidates: [MemoryCandidate] = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard let tag else { return true }
            guard let category = categoryFor(tag) else { return true }

            let entity = String(text[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard entity.count >= minEntityLength else { return true }
            guard seen.insert(entity.lowercased()).inserted else { return true }

            candidates.append(MemoryCandidate(
                id: UUID(),
                content: snippet(entity: entity, tag: tag),
                kind: .fact,
                category: category,
                sourceConversationID: message.conversationID,
                sourceMessageID: message.id,
                proposedAt: .now,
                extractionMethod: .naturalLanguage
            ))

            return true
        }

        return candidates
    }

    // MARK: - Private

    private static func categoryFor(_ tag: NLTag) -> MemoryFact.Category? {
        switch tag {
        case .personalName:     return .relationships
        case .organizationName: return .work
        case .placeName:        return .personal
        default:                return nil
        }
    }

    private static func snippet(entity: String, tag: NLTag) -> String {
        let label: String
        switch tag {
        case .personalName:     label = "Mentioned person"
        case .organizationName: label = "Mentioned organization"
        case .placeName:        label = "Mentioned place"
        default:                label = "Mentioned"
        }
        return "\(label): \(entity)"
    }
}
