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
    /// filtering out anything that's too short, too long, below the
    /// confidence floor, or over the per-message item cap.
    ///
    /// - Parameters:
    ///   - confidenceFloor: Items with explicit confidence below this
    ///     threshold are dropped. Items with no confidence field pass.
    ///   - maxItems: Hard cap on total candidates returned (facts +
    ///     episodes combined). Facts are prioritised: we fill facts first,
    ///     then episodes up to the remaining budget.
    func toCandidates(
        sourceConversationID: UUID,
        sourceMessageID: UUID,
        confidenceFloor: Double = 0.4,
        maxItems: Int = 5
    ) -> [MemoryCandidate] {
        var candidates: [MemoryCandidate] = []

        for fact in facts {
            guard candidates.count < maxItems else { break }
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
            guard candidates.count < maxItems else { break }
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
