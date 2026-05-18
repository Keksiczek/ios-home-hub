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
        do {
            facts = try await store.loadMemoryFacts()
        } catch {
            HHLog.memory.error("loadMemoryFacts failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            episodes = try await store.loadMemoryEpisodes()
        } catch {
            HHLog.memory.error("loadMemoryEpisodes failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Fact mutation

    /// Wraps an `async throws` persistence call so disk-write failures get
    /// logged via `HHLog.memory` instead of being silently dropped by `try?`.
    /// Mutations to the in-memory state still happen — the user sees the
    /// change immediately — but a failed save now leaves a paper trail in
    /// Console.app.
    ///
    /// `description` is a plain `String` rather than an `@autoclosure`:
    /// OSLog's underlying message machinery uses an escaping autoclosure
    /// of its own, and after the `try await work()` suspension we'd be
    /// capturing a non-escaping autoclosure across an actor boundary.
    /// The strings the callers pass are tiny — eager evaluation costs
    /// nothing and avoids the Swift 6 "escaping autoclosure captures
    /// non-escaping parameter" error.
    private func persist(_ description: String, _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            HHLog.memory.error("\(description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func add(_ fact: MemoryFact) async {
        if let idx = facts.firstIndex(where: { $0.id == fact.id }) {
            await embeddings.invalidateCache(for: facts[idx].content)
            facts[idx] = fact
        } else {
            facts.append(fact)
        }
        await persist("save(fact:\(fact.id))") { try await self.store.save(fact: fact) }
        WidgetBridge.updateWidget(facts: facts, keepLastMessage: true)
    }

    func update(_ fact: MemoryFact) async {
        await add(fact)
    }

    func delete(_ id: UUID) async {
        if let fact = facts.first(where: { $0.id == id }) {
            await embeddings.invalidateCache(for: fact.content)
        }
        facts.removeAll { $0.id == id }
        await persist("delete(fact:\(id))") { try await self.store.deleteMemoryFact(id: id) }
        WidgetBridge.updateWidget(facts: facts, keepLastMessage: true)
    }

    func setDisabled(_ disabled: Bool, for id: UUID) async {
        guard let idx = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[idx].disabled = disabled
        let snapshot = facts[idx]
        await persist("setDisabled(fact:\(id))") { try await self.store.save(fact: snapshot) }
        WidgetBridge.updateWidget(facts: facts, keepLastMessage: true)
    }

    func setPinned(_ pinned: Bool, for id: UUID) async {
        guard let idx = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[idx].pinned = pinned
        let snapshot = facts[idx]
        await persist("setPinned(fact:\(id))") { try await self.store.save(fact: snapshot) }
        WidgetBridge.updateWidget(facts: facts, keepLastMessage: true)
    }

    // MARK: - Episode mutation

    func add(_ episode: MemoryEpisode) async {
        if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
            episodes[idx] = episode
        } else {
            episodes.append(episode)
        }
        await persist("save(episode:\(episode.id))") { try await self.store.save(episode: episode) }
    }

    func deleteEpisode(_ id: UUID) async {
        episodes.removeAll { $0.id == id }
        await persist("delete(episode:\(id))") { try await self.store.deleteMemoryEpisode(id: id) }
    }

    func setEpisodeDisabled(_ disabled: Bool, for id: UUID) async {
        guard let idx = episodes.firstIndex(where: { $0.id == id }) else { return }
        episodes[idx].disabled = disabled
        let snapshot = episodes[idx]
        await persist("setDisabled(episode:\(id))") { try await self.store.save(episode: snapshot) }
    }

    // MARK: - Duplicate detection

    /// A pair of facts the heuristic deemed near-duplicates of one
    /// another. Surfaced in the Memory tab so the user can merge or
    /// delete redundant entries without combing through the list
    /// manually. The pair is unordered conceptually; we expose
    /// `primary` / `duplicate` only so the UI has a stable preview
    /// to render — the user picks the keeper at merge time.
    struct DuplicatePair: Identifiable, Hashable {
        let id: UUID = UUID()
        let primary: MemoryFact
        let duplicate: MemoryFact
        /// 0…1 confidence the pair is genuinely duplicate. Used for
        /// sorting so the highest-confidence suggestions appear at
        /// the top of the review sheet.
        let score: Double
    }

    /// Returns pairs of active facts that are likely duplicates.
    ///
    /// Cheap, deterministic heuristic — runs synchronously on the
    /// main actor in <1ms for typical libraries (<100 facts):
    ///   - Same category buckets compared pairwise.
    ///   - Token Jaccard similarity on lowercased, alphanumerics-only
    ///     splits. ≥ 0.65 → flagged. Tuned empirically against the
    ///     extraction test fixtures.
    ///   - Substring containment (one is wholly inside the other,
    ///     after trimming) → always flagged with score 1.0.
    ///
    /// Skips pinned + disabled facts on both sides — pinned facts
    /// are user-blessed (treating them as duplicates would be
    /// annoying), disabled ones are already excluded from prompts
    /// so deduping them adds noise without value.
    ///
    /// Each fact appears in at most one pair so the user reviews a
    /// linear queue rather than a graph (which would force them to
    /// reason about transitive merges).
    func findDuplicateFacts(threshold: Double = 0.65) -> [DuplicatePair] {
        let candidates = facts.filter { !$0.disabled && !$0.pinned }
        guard candidates.count >= 2 else { return [] }

        var taken = Set<UUID>()
        var pairs: [DuplicatePair] = []

        // Group by category — duplicates across categories are
        // intentionally hidden (a "work" preference and a "personal"
        // preference about the same topic are legitimately distinct
        // signals to the model).
        let byCategory = Dictionary(grouping: candidates, by: \.category)
        for (_, group) in byCategory where group.count >= 2 {
            for i in 0..<group.count {
                let a = group[i]
                if taken.contains(a.id) { continue }
                for j in (i+1)..<group.count {
                    let b = group[j]
                    if taken.contains(b.id) { continue }
                    let s = Self.similarity(a.content, b.content)
                    guard s >= threshold else { continue }
                    pairs.append(.init(primary: a, duplicate: b, score: s))
                    taken.insert(a.id)
                    taken.insert(b.id)
                    break
                }
            }
        }
        return pairs.sorted { $0.score > $1.score }
    }

    /// Token-Jaccard similarity over the alphanumeric word splits of
    /// the two strings. Returns 1.0 for substring containment so the
    /// "I prefer short answers" vs "I prefer short answers in the
    /// morning" case is caught even though Jaccard alone would only
    /// score ~0.5 there.
    private static func similarity(_ a: String, _ b: String) -> Double {
        let aTrim = a.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let bTrim = b.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !aTrim.isEmpty, !bTrim.isEmpty else { return 0 }
        if aTrim == bTrim { return 1.0 }
        if aTrim.contains(bTrim) || bTrim.contains(aTrim) { return 1.0 }

        let tokensA = Set(aTrim.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let tokensB = Set(bTrim.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return 0 }
        let inter = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        return Double(inter) / Double(union)
    }

    /// Merges `duplicate` into `keeper`: deletes the duplicate and
    /// returns the still-present keeper unchanged. Provenance fields
    /// on the keeper are NOT overwritten — keeping the original
    /// source link is the correct call since the user explicitly
    /// chose which row to retain.
    func mergeDuplicate(keeperID: UUID, duplicateID: UUID) async {
        guard keeperID != duplicateID else { return }
        await delete(duplicateID)
    }

    // MARK: - Clear all

    func clearAll() async {
        for fact in facts {
            await persist("clearAll/delete(fact:\(fact.id))") { try await self.store.deleteMemoryFact(id: fact.id) }
        }
        for episode in episodes {
            await persist("clearAll/delete(episode:\(episode.id))") { try await self.store.deleteMemoryEpisode(id: episode.id) }
        }
        facts.removeAll()
        episodes.removeAll()
        candidates.removeAll()
        await embeddings.invalidateCache()
        WidgetBridge.updateWidget(facts: facts, keepLastMessage: true)
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
    /// **Pinned facts get a reserved slot.** A user who pinned 20 facts
    /// used to lose 12 of them to the hard `prefix(limit)` cap — pin
    /// was effectively just a sort-priority. Now pinned facts bypass
    /// the limit entirely (they're returned in full), and `limit`
    /// caps only the *non-pinned* tail. A turn with `limit: 8` and
    /// 20 pinned facts now surfaces all 20 + the top 8 relevant
    /// non-pinned.
    ///
    /// **Cost guard.** The pin set is unbounded in theory; if a user
    /// somehow pins hundreds of facts they could blow the prompt
    /// budget. We let the downstream `PromptTokenBudgeter` deal with
    /// that — it caps the facts block as part of system-prompt
    /// trimming. Better to over-include here and let the budget enforce
    /// at the proper layer than to silently drop a user-curated pin.
    func relevantFacts(for input: String, limit: Int) async -> [MemoryFact] {
        guard settings.current.memoryEnabled else { return [] }

        let activeFacts = facts.filter { !$0.disabled }
        guard !activeFacts.isEmpty else { return [] }

        // Split pinned (reserved) from non-pinned (compete for `limit`).
        // Order pinned by createdAt descending so the most-recently-
        // pinned shows up first — matches the user's mental "I just
        // pinned this important fact" expectation.
        let pinned = activeFacts.filter { $0.pinned }
            .sorted { $0.createdAt > $1.createdAt }
        let nonPinned = activeFacts.filter { !$0.pinned }

        guard !nonPinned.isEmpty else {
            // Only pinned facts exist — return them all, no scoring
            // needed (everything is "relevant" by user decree).
            return pinned
        }

        // Try semantic scoring first — only on non-pinned candidates
        // (pinned are already guaranteed inclusion).
        let semanticScores = await embeddings.batchSimilarity(
            query: input,
            candidates: nonPinned.map(\.content)
        )

        let scored: [(MemoryFact, Double)]
        if let semanticScores {
            scored = zip(nonPinned, semanticScores).map { fact, sim in
                (fact, max(sim, 0))
            }
        } else {
            // Keyword fallback
            let normalized = input.lowercased()
            scored = nonPinned.map { fact in
                var score = 0.0
                let words = fact.content
                    .lowercased()
                    .split(whereSeparator: { !$0.isLetter })
                for word in words where word.count > 3 && normalized.contains(word) {
                    score += 0.15
                }
                return (fact, score)
            }
        }

        // Drop non-pinned facts that scored zero — no overlap with
        // the query, would only dilute context. Take top-`limit` and
        // prepend the (always-included) pinned set.
        let relevantNonPinned = scored
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)

        return pinned + Array(relevantNonPinned)
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

    /// Adds a single candidate directly — used by paths that already
    /// produced the candidate (e.g. `ConversationService.autoEpisodizeIdleConversations`)
    /// and don't need to run the extraction pipeline first.
    /// De-duplicates by source-message ID so a re-fire of the same
    /// auto-episodization (e.g. user backgrounded twice with no new
    /// turns) doesn't stack identical proposals in the review list.
    func appendCandidate(_ candidate: MemoryCandidate) async {
        guard settings.current.memoryEnabled else { return }
        let alreadyProposed = candidates.contains {
            $0.sourceMessageID == candidate.sourceMessageID && $0.kind == candidate.kind
        }
        guard !alreadyProposed else { return }
        candidates.append(candidate)
    }

    // MARK: - Bulk candidate review

    /// Accept every pending candidate in one pass. Used by the
    /// "Approve all" action in `MemoryView.candidatesSection`. Order
    /// matches insertion (the user has already eyeballed them in that
    /// order); `accept(_:)` removes each from the pending list so the
    /// final state is `candidates == []`.
    func acceptAllCandidates() async {
        // Snapshot before iterating — `accept(_:)` mutates `candidates`
        // and a live iteration would skip every other entry.
        let snapshot = candidates
        for candidate in snapshot {
            await accept(candidate)
        }
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
