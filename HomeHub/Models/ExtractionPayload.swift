import Foundation

/// Schema for the structured extraction JSON output. The local model
/// is instructed to return exactly this shape; anything that doesn't
/// decode cleanly triggers a fallback to heuristic extraction.
struct ExtractionPayload: Codable, Equatable {
    var facts: [ExtractedFact]
    var episodes: [ExtractedEpisode]

    struct ExtractedFact: Codable, Equatable {
        var content: String
        var category: String
        var confidence: Double?
    }

    struct ExtractedEpisode: Codable, Equatable {
        var summary: String
        var confidence: Double?
    }

    // MARK: - Validation

    /// Maps raw extraction output into validated `MemoryCandidate`s,
    /// filtering out anything that's too short, too long, or below
    /// the confidence floor.
    func toCandidates(
        sourceConversationID: UUID,
        sourceMessageID: UUID,
        confidenceFloor: Double = 0.4
    ) -> [MemoryCandidate] {
        var candidates: [MemoryCandidate] = []

        for fact in facts {
            let trimmed = fact.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 5, trimmed.count <= 300 else { continue }
            if let c = fact.confidence, c < confidenceFloor { continue }
            let category = MemoryFact.Category(rawValue: fact.category) ?? .other
            candidates.append(MemoryCandidate(
                id: UUID(),
                content: trimmed,
                kind: .fact,
                category: category,
                sourceConversationID: sourceConversationID,
                sourceMessageID: sourceMessageID,
                proposedAt: .now,
                extractionMethod: .structured
            ))
        }

        for episode in episodes {
            let trimmed = episode.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 5, trimmed.count <= 500 else { continue }
            if let c = episode.confidence, c < confidenceFloor { continue }
            candidates.append(MemoryCandidate(
                id: UUID(),
                content: trimmed,
                kind: .episode,
                category: .other,
                sourceConversationID: sourceConversationID,
                sourceMessageID: sourceMessageID,
                proposedAt: .now,
                extractionMethod: .structured
            ))
        }

        return candidates
    }

    /// True when the payload decoded but contains nothing actionable.
    var isEmpty: Bool { facts.isEmpty && episodes.isEmpty }
}
