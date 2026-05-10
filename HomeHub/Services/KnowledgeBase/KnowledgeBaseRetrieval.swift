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
        guard let queryVec = await embedder.embeddingVector(for: query.queryText),
              !queryVec.isEmpty else {
            return []
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

        var scored: [RetrievedChunk] = []
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
                let sim = Self.cosine(queryVec, entry.vectors[i])
                if sim >= query.minRelevance {
                    scored.append(RetrievedChunk(
                        document: entry.document,
                        chunk: chunk,
                        similarity: sim
                    ))
                }
            }
        }

        scored.sort { $0.similarity > $1.similarity }
        return Array(scored.prefix(query.maxChunks))
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
