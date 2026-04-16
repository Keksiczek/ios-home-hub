import Foundation
import SwiftUI

/// User-controlled long-term memory.
///
/// Responsibilities:
/// - load / save / delete `MemoryFact`s and `MemoryEpisode`s
/// - surface `MemoryCandidate`s proposed by extraction for review
/// - rank relevant facts and episodes for a given user turn
///
/// v2: supports both durable facts and episodic summaries. Candidates
/// can be either kind and are reviewed through the same UI flow.
/// The user can always wipe everything from the Memory tab, and
/// memory can be toggled off entirely from Settings.
@MainActor
final class MemoryService: ObservableObject {
    @Published private(set) var facts: [MemoryFact] = []
    @Published private(set) var episodes: [MemoryEpisode] = []
    @Published private(set) var candidates: [MemoryCandidate] = []

    private let store: any Store
    private let settings: SettingsService
    private let extractor: MemoryExtractionService
    private let embeddings: EmbeddingService

    init(
        store: any Store,
        settings: SettingsService,
        extractor: MemoryExtractionService,
        embeddings: EmbeddingService = EmbeddingService()
    ) {
        self.store = store
        self.settings = settings
        self.extractor = extractor
        self.embeddings = embeddings
    }

    func load() async {
        if let loaded = try? await store.loadMemoryFacts() {
            facts = loaded
        }
        if let loaded = try? await store.loadMemoryEpisodes() {
            episodes = loaded
        }
    }

    // MARK: - Fact mutation

    func add(_ fact: MemoryFact) async {
        if let idx = facts.firstIndex(where: { $0.id == fact.id }) {
            await embeddings.invalidateCache(for: facts[idx].content)
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
        if let fact = facts.first(where: { $0.id == id }) {
            await embeddings.invalidateCache(for: fact.content)
        }
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

    // MARK: - Episode mutation

    func add(_ episode: MemoryEpisode) async {
        if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
            episodes[idx] = episode
        } else {
            episodes.append(episode)
        }
        try? await store.save(episode: episode)
    }

    func deleteEpisode(_ id: UUID) async {
        episodes.removeAll { $0.id == id }
        try? await store.deleteMemoryEpisode(id: id)
    }

    func setEpisodeDisabled(_ disabled: Bool, for id: UUID) async {
        guard let idx = episodes.firstIndex(where: { $0.id == id }) else { return }
        episodes[idx].disabled = disabled
        try? await store.save(episode: episodes[idx])
    }

    // MARK: - Clear all

    func clearAll() async {
        for fact in facts {
            try? await store.deleteMemoryFact(id: fact.id)
        }
        for episode in episodes {
            try? await store.deleteMemoryEpisode(id: episode.id)
        }
        facts.removeAll()
        episodes.removeAll()
        candidates.removeAll()
        await embeddings.invalidateCache()
    }

    // MARK: - Retrieval

    /// Returns facts relevant to the current user input.
    ///
    /// Scoring strategy (in priority order):
    /// 1. **Semantic** — NLContextualEmbedding cosine similarity when
    ///    available (A18 Pro / M-series with downloaded assets).
    /// 2. **Keyword** — cheap word-overlap fallback on older hardware
    ///    or before embedding assets are downloaded.
    ///
    /// Pinned facts always get a 1.0 base score bonus.
    func relevantFacts(for input: String, limit: Int) async -> [MemoryFact] {
        guard settings.current.memoryEnabled else { return [] }

        let activeFacts = facts.filter { !$0.disabled }
        guard !activeFacts.isEmpty else { return [] }

        // Try semantic scoring first
        let semanticScores = await embeddings.batchSimilarity(
            query: input,
            candidates: activeFacts.map(\.content)
        )

        let scored: [(MemoryFact, Double)]
        if let semanticScores {
            scored = zip(activeFacts, semanticScores).map { fact, sim in
                let pinBonus = fact.pinned ? 1.0 : 0.0
                return (fact, max(sim, 0) + pinBonus)
            }
        } else {
            // Keyword fallback
            let normalized = input.lowercased()
            scored = activeFacts.map { fact in
                var score = fact.pinned ? 1.0 : 0.0
                let words = fact.content
                    .lowercased()
                    .split(whereSeparator: { !$0.isLetter })
                for word in words where word.count > 3 && normalized.contains(word) {
                    score += 0.15
                }
                return (fact, score)
            }
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Returns episodes relevant to the current user input.
    ///
    /// Scoring: semantic similarity (NLContextualEmbedding) with recency
    /// boost, falling back to keyword overlap on unsupported hardware.
    func relevantEpisodes(for input: String, limit: Int) async -> [MemoryEpisode] {
        guard settings.current.memoryEnabled else { return [] }
        let now = Date.now

        let activeEpisodes = episodes.filter { $0.approved && !$0.disabled }
        guard !activeEpisodes.isEmpty else { return [] }

        // Try semantic scoring first
        let semanticScores = await embeddings.batchSimilarity(
            query: input,
            candidates: activeEpisodes.map(\.summary)
        )

        let scored: [(MemoryEpisode, Double)]
        if let semanticScores {
            scored = zip(activeEpisodes, semanticScores).map { episode, sim in
                var score = max(sim, 0)
                // Recency boost
                let age = now.timeIntervalSince(episode.createdAt)
                let sevenDays: TimeInterval = 7 * 24 * 3600
                if age < sevenDays {
                    score += 0.3 * max(0, 1.0 - age / sevenDays)
                }
                return (episode, score)
            }
        } else {
            // Keyword fallback
            let normalized = input.lowercased()
            scored = activeEpisodes.map { episode in
                var score = 0.0
                let words = episode.summary
                    .lowercased()
                    .split(whereSeparator: { !$0.isLetter })
                for word in words where word.count > 3 && normalized.contains(word) {
                    score += 0.2
                }
                let age = now.timeIntervalSince(episode.createdAt)
                let sevenDays: TimeInterval = 7 * 24 * 3600
                if age < sevenDays {
                    score += 0.3 * max(0, 1.0 - age / sevenDays)
                }
                return (episode, score)
            }
        }

        return scored
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Candidates

    /// Consider a newly-sent user message for memory extraction. Runs
    /// off the main actor since extraction may perform inference.
    ///
    /// Callers on the hot path should invoke this from a
    /// `Task.detached(priority: .background)` so the extraction's second
    /// LLM inference pass doesn't compete with the user-visible
    /// assistant stream (see `ConversationService.performSend`).
    func consider(message: Message) async {
        guard settings.current.memoryEnabled,
              settings.current.autoExtractMemory else { return }
        let proposed = await extractor.extract(from: message)
        guard !proposed.isEmpty else { return }
        candidates.append(contentsOf: proposed)
    }

    func accept(_ candidate: MemoryCandidate) async {
        switch candidate.kind {
        case .fact:
            let fact = MemoryFact(
                id: UUID(),
                content: candidate.content,
                category: candidate.category,
                source: .conversationExtraction,
                confidence: 0.7,
                createdAt: .now,
                lastUsedAt: nil,
                pinned: false,
                disabled: false,
                sourceConversationID: candidate.sourceConversationID,
                sourceMessageID: candidate.sourceMessageID,
                extractionMethod: candidate.extractionMethod
            )
            await add(fact)

        case .episode:
            let episode = MemoryEpisode(
                id: UUID(),
                summary: candidate.content,
                sourceConversationID: candidate.sourceConversationID,
                sourceMessageID: candidate.sourceMessageID,
                createdAt: .now,
                lastRelevantAt: nil,
                approved: true,
                disabled: false,
                extractionMethod: candidate.extractionMethod
            )
            await add(episode)
        }
        candidates.removeAll { $0.id == candidate.id }
    }

    func reject(candidateID: UUID) {
        candidates.removeAll { $0.id == candidateID }
    }

    func rejectAllCandidates() {
        candidates.removeAll()
    }
}
