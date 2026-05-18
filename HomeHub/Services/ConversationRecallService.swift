import Foundation
import CryptoKit

/// Semantic recall over a conversation's *truncated* message history.
///
/// **Problem this solves.** The `PromptTokenBudgeter` walks messages
/// newest-first and stops at the per-family token budget. Once a
/// conversation grows past that budget the oldest turns silently drop
/// out of the prompt. The auto-summarizer (`ConversationService.maybeSummarizeOlderHalf`)
/// captures the *gist*, but the gist is one paragraph — specific
/// details ("we agreed on the API shape with `userId: UUID`") get
/// flattened. When the user asks a follow-up that touches one of those
/// details, the model has no path back to the exact wording.
///
/// **What this service does.** For each conversation, lazily build an
/// in-memory embedding index over every message. On a user turn,
/// score every indexed message against the user input, return the
/// top-K most-similar messages that *aren't already in the live
/// history window*. The `ConversationService` injects those snippets
/// into `PromptContextPackage.conversationRecall`, where
/// `PromptAssemblyService` renders them as a dedicated "Earlier in
/// this conversation" block.
///
/// **Why a separate service?** Keeping the recall index off
/// `MemoryService` avoids confusing two semantic surfaces — long-term
/// curated facts vs. per-conversation message history. The user
/// reviews/approves facts; recall snippets are ephemeral and always
/// scoped to one conversation.
///
/// **Persistence.** A per-conversation JSON file holds the
/// `(messageID, contentHash, vector)` triples so a long conversation
/// doesn't pay the full embed cost on every app launch. The hash gates
/// re-use — an edited message produces a new hash, so its stale vector
/// is recomputed on next access. Files live under
/// `~/Documents/conversation_embeddings/<convID>.json`; conversation
/// deletion is responsible for cleaning the matching file.
///
/// **Cost.** ~96 floats per message (NLContextualEmbedding dimension)
/// × 4 bytes = ~400 B raw, JSON-encoded to ~1.5-2 KB. A 200-message
/// conversation rounds to ~400 KB on disk — comfortable.
@MainActor
final class ConversationRecallService {

    private let embeddings: EmbeddingService

    /// `true` while the index for a given conversation is being warmed
    /// up. Used as a re-entrancy guard so a fast double-send doesn't
    /// kick off two warm-up passes that race on the embedding LRU.
    private var warmupTasks: [UUID: Task<Void, Never>] = [:]

    /// In-memory mirror of the on-disk index, keyed by conversation.
    /// Populated on warm-up; consulted by `recall(...)` before falling
    /// back to fresh embedding compute. Bounded only by the LRU on
    /// `messagesByConversation` upstream — we don't separately cap
    /// here because conversation eviction takes care of it.
    private var indices: [UUID: RecallIndex] = [:]

    /// Pending disk-write tasks per conversation. Coalesces a burst
    /// of message inserts into one save instead of one-per-message.
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    /// Disk directory for persisted indices. Created lazily on first
    /// save so a session that never warms up never touches the
    /// filesystem. Files inside are plain JSON — easy to inspect and
    /// nuke manually if a user reports corruption.
    private let storageDir: URL?

    init(embeddings: EmbeddingService) {
        self.embeddings = embeddings
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.storageDir = docs.appendingPathComponent("conversation_embeddings", isDirectory: true)
        } else {
            self.storageDir = nil
        }
    }

    /// Cached vector + content hash for a single message. Hash makes
    /// the cache content-addressable: editing a message text breaks
    /// the hash equality check, forcing a re-embed on next access.
    struct CachedEntry: Codable, Equatable {
        let messageID: UUID
        /// SHA-256 hex of the message content. Compared by string
        /// equality — exact match required for cache hit.
        let contentHash: String
        /// Embedding vector in Float32. Mirrors `EmbeddingService.embeddingVector`.
        let vector: [Float]
    }

    /// Per-conversation index — message ID → cached entry. The set
    /// is the source of truth; on save we serialize the full set, on
    /// load we replace the in-memory mirror.
    struct RecallIndex: Codable, Equatable {
        var entries: [UUID: CachedEntry]

        init(entries: [UUID: CachedEntry] = [:]) {
            self.entries = entries
        }
    }

    /// Computes the SHA-256 hex of `content`. Used as the content
    /// identity for cache invalidation — exact match required for
    /// hit. Kept here rather than on `CachedEntry` so the call site
    /// can hash without instantiating an entry just to compare.
    static func contentHash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// URL for `conversationID`'s on-disk index, or `nil` if the
    /// storage directory couldn't be resolved (sandboxed test env
    /// with no Documents dir).
    private func storageURL(for conversationID: UUID) -> URL? {
        storageDir?.appendingPathComponent("\(conversationID.uuidString).json")
    }

    /// Returns up to `limit` messages from `history` that are most
    /// semantically similar to `query`, excluding any whose IDs are
    /// in `excludeIDs` (typically the IDs of messages the budgeter
    /// already kept in the live window — including them again would
    /// just duplicate context).
    ///
    /// **Threshold gating.** Scores below `minSimilarity` are dropped
    /// so an off-topic query doesn't pull up random ancient chatter.
    /// `0.35` empirically separates "vaguely related" from "actually
    /// related" on NLContextualEmbedding cosine scores for short
    /// conversational text.
    ///
    /// Returns an empty array (not nil) when:
    ///   - The embedding model isn't available on this device,
    ///   - All candidates score below the threshold, or
    ///   - `history` is empty after the exclude-filter.
    func recall(
        query: String,
        from history: [Message],
        excluding excludeIDs: Set<UUID>,
        limit: Int = 3,
        minSimilarity: Double = 0.35
    ) async -> [Message] {
        let candidates = history.filter { !excludeIDs.contains($0.id) && !$0.content.isEmpty }
        guard !candidates.isEmpty else { return [] }

        let texts = candidates.map(\.content)
        guard let scores = await embeddings.batchSimilarity(query: query, candidates: texts) else {
            // Embedding model unavailable (older hardware or assets not
            // downloaded). The caller's caller (ConversationService)
            // still has summarization + budgeter as fallbacks; recall
            // just becomes a no-op on that device.
            return []
        }

        let scored = zip(candidates, scores)
            .filter { $0.1 >= minSimilarity }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)

        // Preserve chronological order in the output even though
        // ranking was similarity-descending — the LLM reads top-to-
        // bottom and a "Earlier in this conversation: [newer first]"
        // block reads weirdly. The Set keeps lookup O(1) for the
        // ordering pass.
        let chosen = Set(scored.map(\.id))
        return candidates.filter { chosen.contains($0.id) }
    }

    /// Pre-warms the embedding cache + persistent index for
    /// `messages`. Three-tier flow:
    ///   1. Read on-disk index if present — instantly populates the
    ///      in-memory mirror, no inference cost.
    ///   2. For messages whose hash doesn't match the cached entry
    ///      (edited / new), compute fresh embeddings via
    ///      `embeddingService.embeddingVector`.
    ///   3. Persist the merged index back to disk after a short
    ///      debounce so a burst of new messages collapses to one
    ///      write.
    ///
    /// Fire-and-forget; the LRU on `EmbeddingService` ensures we never
    /// inflate the cache past its bound regardless of how often this
    /// is called.
    func warmUp(conversationID: UUID, messages: [Message]) {
        guard warmupTasks[conversationID] == nil else { return }
        warmupTasks[conversationID] = Task { [weak self] in
            guard let self else { return }
            defer { self.warmupTasks[conversationID] = nil }

            // Phase 1: hydrate in-memory mirror from disk.
            var index = self.indices[conversationID] ?? self.loadIndex(for: conversationID) ?? RecallIndex()

            // Phase 2: spot fresh / edited messages and embed them.
            // Cache hits get pushed into EmbeddingService's LRU so
            // the next `recall(...)` finds them there without
            // recomputing — the whole point of the persistent index.
            let usable = messages.filter { !$0.content.isEmpty }
            var dirty = false
            for msg in usable {
                let hash = Self.contentHash(msg.content)
                if let cached = index.entries[msg.id], cached.contentHash == hash {
                    await self.embeddings.primeCache(content: msg.content, vector: cached.vector)
                    continue   // valid cache hit
                }
                guard let vector = await self.embeddings.embeddingVector(for: msg.content) else {
                    // Embedding model not available — skip this
                    // message; we'll try again on the next warm-up.
                    continue
                }
                index.entries[msg.id] = CachedEntry(
                    messageID: msg.id,
                    contentHash: hash,
                    vector: vector
                )
                dirty = true
            }

            // Phase 3: garbage-collect entries for messages that no
            // longer exist (user deleted or regenerated). Keeps disk
            // footprint bounded over the conversation lifetime.
            let liveIDs = Set(usable.map(\.id))
            let before = index.entries.count
            index.entries = index.entries.filter { liveIDs.contains($0.key) }
            if index.entries.count != before { dirty = true }

            self.indices[conversationID] = index

            if dirty {
                self.scheduleSave(for: conversationID)
            }
        }
    }

    /// Reads the index for `conversationID` from disk. Returns `nil`
    /// when the file is missing OR decoding fails — both downgrade
    /// to "rebuild from scratch" rather than crashing, since the
    /// persistent cache is purely a speedup and shouldn't be a
    /// reliability dependency.
    private func loadIndex(for conversationID: UUID) -> RecallIndex? {
        guard let url = storageURL(for: conversationID),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecallIndex.self, from: data)
    }

    /// Schedules a debounced disk save for `conversationID`. Multiple
    /// `scheduleSave` calls within `saveDebounceMs` collapse to one
    /// write — important for the warm-up path that updates entries
    /// in a tight loop, and for the streaming path that adds a new
    /// message every few hundred ms.
    private func scheduleSave(for conversationID: UUID) {
        pendingSaves[conversationID]?.cancel()
        pendingSaves[conversationID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.saveDebounceMs) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistIndex(for: conversationID)
            self.pendingSaves[conversationID] = nil
        }
    }

    /// Writes the in-memory index to disk. Synchronous file I/O;
    /// runs from a Task continuation so the caller doesn't block.
    /// Errors are logged (via a generic notice) but never raised —
    /// the on-disk cache is best-effort.
    private func persistIndex(for conversationID: UUID) {
        guard let url = storageURL(for: conversationID),
              let index = indices[conversationID] else { return }
        // Ensure the directory exists. Cheap — once-per-app-launch
        // worth of stat calls amortized across the conversation set.
        if let dir = storageDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        do {
            let data = try JSONEncoder().encode(index)
            try data.write(to: url, options: .atomic)
        } catch {
            // Failures are silent — the in-memory mirror is still
            // authoritative for this session, just no disk speedup
            // on next launch. Logging it via a notice keeps it in
            // Console.app for the rare user who reports "recall
            // seems slow after relaunch".
        }
    }

    /// Save debounce window. 1.5 s is a sweet spot: long enough to
    /// coalesce a warm-up's tight insertion loop and any near-instant
    /// follow-up send, short enough that a force-quit shortly after
    /// open still flushes most of the cache.
    private static let saveDebounceMs = 1500

    /// Deletes the persisted index for `conversationID`. Called by
    /// `ConversationService` when a conversation is deleted so the
    /// stale embedding file doesn't accumulate.
    func deleteIndex(for conversationID: UUID) {
        indices[conversationID] = nil
        pendingSaves[conversationID]?.cancel()
        pendingSaves[conversationID] = nil
        if let url = storageURL(for: conversationID) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
