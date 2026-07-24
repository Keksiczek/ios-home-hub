import Foundation
import Accelerate

/// Document-Knowledge-Base retrieval. Loads the persisted vectors
/// per document, computes cosine similarity against the query
/// embedding, and returns the top-k chunks with metadata for
/// citations.
///
/// ## Why a linear scan
/// v1 ranges in the dozens-to-hundreds of documents and a few
/// thousand chunks total. A linear scan over Float32 vectors with
/// vDSP-friendly cosine math is plenty fast (<10 ms for 5k chunks
/// at 512 dim on Apple Silicon). When the corpus grows past that,
/// we can switch to an HNSW or product-quantised index without
/// changing this protocol.
///
/// ## In-memory index cache
/// First retrieval per process loads all (chunks, vectors) for
/// every indexed document into RAM. Subsequent retrievals reuse
/// the cache — eliminating ~N file reads + N binary decodes per
/// query. Invalidated wholesale via `invalidate()` whenever a
/// document mutates (the `KnowledgeBaseService` calls this from
/// `refresh()`); a more granular `invalidate(documentID:)` is
/// also available for surgical updates.
///
/// Queries that miss the embedding (model not loaded yet) return
/// an empty result rather than blowing up — chat code can fall
/// back to keyword grep over chunk text if it wants.
actor KnowledgeBaseRetrievalService: KnowledgeBaseRetrieving {

    private let documentStore: KnowledgeBaseStore
    private let embedder: EmbeddingService

    /// Per-document snapshot kept in memory between retrievals.
    /// Tagged with `lastIndexedAt` so a stale entry (e.g. another
    /// caller reindexed without invalidating) can be detected on
    /// the slow path; the fast path trusts `invalidate()` callers.
    private struct IndexEntry {
        let document: DocumentRecord
        let chunks: [ChunkRecord]
        let vectors: [[Float]]
        let lastIndexedAt: Date?
    }

    /// `nil` = uninitialised, `[:]` = explicitly empty (no indexed
    /// docs found). The distinction matters because we want one
    /// cold-load on first query and not on every empty refresh.
    private var indexCache: [UUID: IndexEntry]?

    init(documentStore: KnowledgeBaseStore, embedder: EmbeddingService) {
        self.documentStore = documentStore
        self.embedder = embedder
    }

    func retrieve(for query: RetrievalQuery) async throws -> [RetrievedChunk] {
        // Dense scoring is ATTEMPTED, not required.
        //
        // This used to be a `guard … else { return [] }` on the query
        // embedding, which made an unavailable embedding backend
        // indistinguishable from an empty corpus — both returned `[]`, with no
        // log. `NLContextualEmbedding`'s assets download separately and can
        // legitimately be missing, so the user imported documents, saw
        // "Indexed", and then the model answered every question as if those
        // documents did not exist. Nothing anywhere explained why.
        //
        // Now a missing embedding degrades to lexical-only retrieval and says
        // so, loudly. `LexicalRetrieval` exists for exactly this.
        let queryVector = await embedder.embeddingVector(for: query.queryText)
        let canScoreDense = !(queryVector ?? []).isEmpty
        if !canScoreDense {
            // A single string literal, not `+`-concatenation: `Logger.error`
            // takes an `OSLogMessage`, which is built from a string literal at
            // the call site — a runtime-composed `String` does not conform.
            HHLog.kb.error("retrieval: query embedding unavailable — falling back to lexical BM25 only. Results will be exact-match biased. This usually means the NLContextualEmbedding assets have not been downloaded.")
        }

        let cache = try await loadCacheIfNeeded()
        guard !cache.isEmpty else { return [] }

        // Filter eligible docs from the cache rather than re-querying
        // the store — the cache is authoritative until invalidated.
        let eligible = cache.values.filter { entry in
            let doc = entry.document
            guard doc.indexingStatus == .indexed else { return false }
            if let workspace = query.workspaceID, doc.workspaceID != workspace { return false }
            if let ids = query.documentIDs, !ids.contains(doc.id) { return false }
            return true
        }
        guard !eligible.isEmpty else { return [] }

        // Flatten to one candidate list so both rankers address the same
        // positions and fusion can align them by index.
        var candidates: [(document: DocumentRecord, chunk: ChunkRecord, vector: [Float])] = []
        for entry in eligible {
            // Cooperative cancellation: a long-running retrieval over
            // a corpus of dozens of documents should bail when the
            // caller's `Task` is cancelled (e.g. user starts typing
            // a new query while the previous one is still scoring).
            try Task.checkCancellation()

            // Defensive: skip docs whose persisted vector count
            // doesn't match the chunk count. This means an ingest
            // was cut short or the on-disk files drifted; the
            // pipeline will fix it on next reindex. Log loudly —
            // a silent skip masked a real bug for too long during
            // pipeline development.
            guard entry.vectors.count == entry.chunks.count else {
                HHLog.kb.error(
                    "retrieval: skipping doc \(entry.document.id, privacy: .public) — vector count \(entry.vectors.count, privacy: .public) ≠ chunk count \(entry.chunks.count, privacy: .public)"
                )
                continue
            }

            for (i, chunk) in entry.chunks.enumerated() {
                candidates.append((entry.document, chunk, entry.vectors[i]))
            }
        }
        guard !candidates.isEmpty else { return [] }

        // ── Dense ranking ────────────────────────────────────────────────
        // `minRelevance` stays a DENSE-only threshold. It is calibrated as a
        // cosine value, so applying it to a BM25 or a fused RRF score would be
        // comparing unrelated scales.
        var denseRanking: [LexicalRetrieval.Scored] = []
        var cosineByIndex: [Int: Float] = [:]
        if let queryVector, canScoreDense {
            for (index, candidate) in candidates.enumerated() {
                let similarity = Self.cosine(queryVector, candidate.vector)
                cosineByIndex[index] = similarity
                if similarity >= query.minRelevance {
                    denseRanking.append(.init(index: index, score: similarity))
                }
            }
            denseRanking.sort { $0.score > $1.score }

            // A corpus indexed before the zero-dimension guard landed in the
            // ingest pipeline scores 0.0 against every query forever, because
            // `cosine` returns 0 on a length mismatch. That is silent data
            // loss wearing an "Indexed" badge, so name it.
            if denseRanking.isEmpty && candidates.allSatisfy({ $0.vector.isEmpty }) {
                HHLog.kb.error("retrieval: every candidate has a zero-dimension vector — this corpus was indexed while the embedder was unavailable and needs reindexing. Serving lexical results only.")
            }
        }

        // ── Lexical ranking ──────────────────────────────────────────────
        // Always computed, even when dense scoring succeeded: its whole value
        // is catching the exact strings — proper nouns, error codes, version
        // numbers — that embeddings are structurally bad at.
        //
        // Re-check cancellation before this second full pass: the dense pass
        // above can be the dominant cost on a large corpus, so a task cancelled
        // during it should not also pay for BM25.
        try Task.checkCancellation()
        let lexicalRanking = LexicalRetrieval.score(
            query: query.queryText,
            documents: candidates.map(\.chunk.text)
        )

        // ── Fuse, cap, classify ──────────────────────────────────────────
        // Pure and unit-tested (`fuseAndRank`) — it owns the load-bearing
        // index-alignment invariant, so it is deliberately extracted from this
        // actor method where it can be exercised without a store or embedder.
        let ranked = Self.fuseAndRank(
            dense: denseRanking,
            lexical: lexicalRanking,
            canScoreDense: canScoreDense,
            maxChunks: query.maxChunks
        )

        return ranked.map { result in
            RetrievedChunk(
                document: candidates[result.index].document,
                chunk: candidates[result.index].chunk,
                similarity: cosineByIndex[result.index] ?? 0,
                rank: result.rank,
                matchKind: result.matchKind
            )
        }
    }

    // MARK: - Fusion + ranking (pure, testable)

    /// One row of the final ranking: which candidate, how it was matched, and
    /// its position. Carries indices only — it is deliberately free of
    /// `DocumentRecord` / `ChunkRecord` so the fusion logic can be unit-tested
    /// with hand-built rankings and no store.
    struct RankedResult: Equatable, Sendable {
        let index: Int
        let matchKind: RetrievedChunk.MatchKind
        let rank: Int
    }

    /// Default ceiling on how many **lexical-only** chunks may enter the final
    /// result when dense scoring is available.
    ///
    /// This is a prompt-injection control, not a quality knob. Dense hits must
    /// clear `minRelevance`; a lexical hit needs only to share a token with the
    /// query, and RRF (correctly) lets a chunk survive on one ranker alone. So
    /// without a cap, a document — for example an imported web page whose text
    /// was crafted to be keyword-dense in the vocabulary a user is likely to
    /// ask about — could occupy several `maxChunks` slots with `.lexical`
    /// matches carrying no topical (dense) support, displacing genuinely
    /// relevant chunks and injecting attacker-influenced text into the prompt.
    ///
    /// Capping lexical-*only* survivors bounds that: exact-match recall (the
    /// reason lexical exists) is preserved for a couple of hits, while
    /// keyword-spam cannot flood the context. Hybrid matches (dense **and**
    /// lexical agree) and pure dense matches are never capped — they have
    /// topical support.
    ///
    /// An absolute BM25 floor was the obvious alternative and was rejected for
    /// the same reason RRF is used over a weighted score sum: BM25 is unbounded
    /// and its scale is corpus-dependent, so any fixed threshold drifts as the
    /// corpus grows. A count cap is scale-free.
    static let defaultLexicalOnlyCap = 2

    /// Fuses the dense and lexical rankings, caps lexical-only survivors, and
    /// classifies each result's `matchKind`, in final rank order.
    ///
    /// `dense` and `lexical` MUST index into the same candidate array (this is
    /// the invariant the caller establishes by scoring both against one
    /// flattened `candidates` list). Positions in the returned array are the
    /// authoritative rank.
    ///
    /// The lexical-only cap applies **only when dense scoring ran**. When
    /// `canScoreDense` is false, lexical is the only signal available, so
    /// capping it would cripple the very fallback it exists to provide — in
    /// that mode the cap is lifted to `maxChunks`.
    static func fuseAndRank(
        dense: [LexicalRetrieval.Scored],
        lexical: [LexicalRetrieval.Scored],
        canScoreDense: Bool,
        maxChunks: Int,
        lexicalOnlyCap: Int = defaultLexicalOnlyCap
    ) -> [RankedResult] {
        guard maxChunks > 0 else { return [] }

        let denseIndices = Set(dense.map(\.index))
        let lexicalIndices = Set(lexical.map(\.index))
        let fused = canScoreDense
            ? LexicalRetrieval.fuse([dense, lexical])
            : lexical

        // Lexical-only survivors are unbounded exactly when lexical is all we
        // have; otherwise they are bounded by the injection cap.
        let effectiveCap = canScoreDense ? lexicalOnlyCap : maxChunks

        var results: [RankedResult] = []
        var lexicalOnlyAdmitted = 0
        for scored in fused {
            let inDense = denseIndices.contains(scored.index)
            let inLexical = lexicalIndices.contains(scored.index)
            let kind: RetrievedChunk.MatchKind =
                inDense && inLexical ? .hybrid : (inDense ? .dense : .lexical)

            if kind == .lexical {
                guard lexicalOnlyAdmitted < effectiveCap else { continue }
                lexicalOnlyAdmitted += 1
            }

            results.append(RankedResult(index: scored.index, matchKind: kind, rank: results.count))
            if results.count >= maxChunks { break }
        }
        return results
    }

    // MARK: - Cache management

    /// Drops the entire in-memory snapshot. Cheap; the next query
    /// rebuilds from disk. Called by `KnowledgeBaseService.refresh`.
    func invalidate() {
        indexCache = nil
    }

    /// Surgical invalidation for a single document. Used by the
    /// pipeline when it knows exactly which doc changed (reindex,
    /// delete, fresh ingest) — avoids re-reading the whole corpus.
    func invalidate(documentID: UUID) {
        indexCache?.removeValue(forKey: documentID)
    }

    private func loadCacheIfNeeded() async throws -> [UUID: IndexEntry] {
        if let indexCache { return indexCache }
        let docs = try await documentStore.loadDocuments()
        var cache: [UUID: IndexEntry] = [:]
        cache.reserveCapacity(docs.count)
        for doc in docs where doc.indexingStatus == .indexed {
            do {
                let chunks = try await documentStore.loadChunks(documentID: doc.id)
                guard let payload = try await documentStore.loadVectors(documentID: doc.id) else {
                    continue
                }
                cache[doc.id] = IndexEntry(
                    document: doc,
                    chunks: chunks,
                    vectors: payload.vectors,
                    lastIndexedAt: doc.lastIndexedAt
                )
            } catch {
                HHLog.kb.error(
                    "retrieval: failed to cache doc \(doc.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        indexCache = cache
        return cache
    }

    // MARK: - Math

    /// Cosine similarity over Float32 vectors via Accelerate's
    /// `vDSP` primitives — `vDSP_dotpr` for the inner product and
    /// `vDSP_svesq` for the squared L2 norms. Single-pass NEON on
    /// Apple Silicon, ~5–10× faster than the Swift loop on a 768-dim
    /// vector. The compiler-vectorised hand loop was fine for the
    /// initial prototype; with retrieval now hot in the chat path
    /// (every prompt assembly call) the constant factor matters.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dot: Float = 0
        var sumA2: Float = 0
        var sumB2: Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                vDSP_dotpr(ap.baseAddress!, 1, bp.baseAddress!, 1, &dot, n)
                vDSP_svesq(ap.baseAddress!, 1, &sumA2, n)
                vDSP_svesq(bp.baseAddress!, 1, &sumB2, n)
            }
        }
        let denom = (sumA2 * sumB2).squareRoot()
        guard denom > 1e-10 else { return 0 }
        return dot / denom
    }
}
