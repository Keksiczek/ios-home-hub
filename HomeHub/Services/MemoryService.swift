import Foundation
import SwiftUI

/// User-controlled long-term memory.
///
/// Responsibilities:
/// - load / save / delete `MemoryFact`s
/// - surface `MemoryCandidate`s proposed by extraction for review
/// - rank relevant facts for a given user turn
///
/// The user can always wipe everything from the Memory tab, and
/// memory can be toggled off entirely from Settings.
@MainActor
final class MemoryService: ObservableObject {
    @Published private(set) var facts: [MemoryFact] = []
    @Published private(set) var candidates: [MemoryCandidate] = []

    private let store: any Store
    private let settings: SettingsService
    private let extractor: MemoryExtractionService

    init(
        store: any Store,
        settings: SettingsService,
        extractor: MemoryExtractionService
    ) {
        self.store = store
        self.settings = settings
        self.extractor = extractor
    }

    func load() async {
        if let loaded = try? await store.loadMemoryFacts() {
            facts = loaded
        }
    }

    // MARK: - Mutation

    func add(_ fact: MemoryFact) async {
        if let idx = facts.firstIndex(where: { $0.id == fact.id }) {
            facts[idx] = fact
        } else {
            facts.append(fact)
        }
        try? await store.save(fact: fact)
    }

    func update(_ fact: MemoryFact) async {
        await add(fact)
    }

    func delete(_ id: UUID) async {
        facts.removeAll { $0.id == id }
        try? await store.deleteMemoryFact(id: id)
    }

    func setDisabled(_ disabled: Bool, for id: UUID) async {
        guard let idx = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[idx].disabled = disabled
        try? await store.save(fact: facts[idx])
    }

    func setPinned(_ pinned: Bool, for id: UUID) async {
        guard let idx = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[idx].pinned = pinned
        try? await store.save(fact: facts[idx])
    }

    func clearAll() async {
        for fact in facts {
            try? await store.deleteMemoryFact(id: fact.id)
        }
        facts.removeAll()
        candidates.removeAll()
    }

    // MARK: - Retrieval

    /// Returns facts relevant to the current user input.
    ///
    /// v1 Simplification: pinned first, then cheap keyword overlap.
    /// Future: on-device embedding (NLContextualEmbedding on A18 /
    /// M-series) + cosine similarity with a small LRU cache.
    func relevantFacts(for input: String, limit: Int) async -> [MemoryFact] {
        guard settings.current.memoryEnabled else { return [] }
        let normalized = input.lowercased()

        let scored: [(MemoryFact, Double)] = facts
            .filter { !$0.disabled }
            .map { fact in
                var score = fact.pinned ? 1.0 : 0.0
                let words = fact.content
                    .lowercased()
                    .split(whereSeparator: { !$0.isLetter })
                for word in words where word.count > 3 && normalized.contains(word) {
                    score += 0.15
                }
                return (fact, score)
            }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Candidates

    /// Consider a newly-sent user message for fact extraction. Runs
    /// off the main actor since extraction is pure and may later
    /// perform heavier work.
    func consider(message: Message) async {
        guard settings.current.memoryEnabled,
              settings.current.autoExtractMemory else { return }
        let proposed = await extractor.extract(from: message)
        guard !proposed.isEmpty else { return }
        candidates.append(contentsOf: proposed)
    }

    func accept(_ candidate: MemoryCandidate) async {
        let fact = MemoryFact(
            id: UUID(),
            content: candidate.content,
            category: candidate.category,
            source: .conversationExtraction,
            confidence: 0.7,
            createdAt: .now,
            lastUsedAt: nil,
            pinned: false,
            disabled: false
        )
        await add(fact)
        candidates.removeAll { $0.id == candidate.id }
    }

    func reject(candidateID: UUID) {
        candidates.removeAll { $0.id == candidateID }
    }

    func rejectAllCandidates() {
        candidates.removeAll()
    }
}
