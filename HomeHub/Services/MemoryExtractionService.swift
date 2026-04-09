import Foundation

/// Proposes `MemoryCandidate`s from a finished user message.
///
/// v1 Simplification: heuristic keyword triggers. Good enough to
/// prove out the user flow and the "review candidates" UI without
/// spending tokens on extraction.
///
/// Future implementation: a second short inference pass on the
/// loaded model with a strict JSON-structured prompt like
/// `Extract durable facts about the user as JSON array...`, then
/// schema-validate the output before surfacing candidates.
actor MemoryExtractionService {

    private struct Trigger {
        let phrase: String
        let category: MemoryFact.Category
    }

    private let triggers: [Trigger] = [
        Trigger(phrase: "my name is",       category: .personal),
        Trigger(phrase: "i live in",        category: .personal),
        Trigger(phrase: "i'm from",         category: .personal),
        Trigger(phrase: "i work at",        category: .work),
        Trigger(phrase: "i work as",        category: .work),
        Trigger(phrase: "my job is",        category: .work),
        Trigger(phrase: "i'm working on",   category: .projects),
        Trigger(phrase: "i'm building",     category: .projects),
        Trigger(phrase: "my project",       category: .projects),
        Trigger(phrase: "i prefer",         category: .preferences),
        Trigger(phrase: "i like",           category: .preferences),
        Trigger(phrase: "i don't like",     category: .preferences),
        Trigger(phrase: "i hate",           category: .preferences),
        Trigger(phrase: "remember that",    category: .other),
        Trigger(phrase: "please remember",  category: .other)
    ]

    func extract(from message: Message) async -> [MemoryCandidate] {
        guard message.role == .user else { return [] }
        let lowered = message.content.lowercased()
        var seen = Set<String>()
        var results: [MemoryCandidate] = []

        for trigger in triggers where lowered.contains(trigger.phrase) {
            let cleaned = message.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = String(cleaned.prefix(160))
            guard seen.insert(trigger.category.rawValue).inserted else { continue }
            results.append(MemoryCandidate(
                id: UUID(),
                content: snippet,
                category: trigger.category,
                sourceConversationID: message.conversationID,
                sourceMessageID: message.id,
                proposedAt: .now
            ))
        }

        return results
    }
}
