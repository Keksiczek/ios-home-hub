import Foundation
import NaturalLanguage

/// On-device semantic embedding via NLContextualEmbedding (iOS 17+).
///
/// Uses the system's contextual embedding model to compute sentence-level
/// vectors and cosine similarity. Falls back gracefully when the embedding
/// model assets aren't available (older hardware, first launch before
/// download completes).
///
/// ## Caching
/// Fact and episode embeddings are cached by content hash. The cache is
/// invalidated when facts/episodes are modified. Input embeddings are
/// not cached (they change every turn).
///
/// ## Thread safety
/// Actor-isolated — safe to call from any context. The embedding model
/// is loaded lazily on first use.
actor EmbeddingService {

    // MARK: - State

    private var embedding: NLContextualEmbedding?
    private var isAvailable: Bool?

    /// Bound on the LRU cache. A typical fact / chat snippet vector is
    /// ~512 doubles ≈ 4 KB, so 256 entries ≈ 1 MB peak. Plenty of head-
    /// room for normal sessions, hard cap so a long-running app session
    /// can't grow the cache without bound.
    private static let cacheCapacity = 256

    /// Cache values keyed by raw text. `cacheOrder` tracks the
    /// most-recently-used order — the front is least-recent and the
    /// first to be evicted when the cache hits `cacheCapacity`.
    private var cache: [String: [Double]] = [:]
    private var cacheOrder: [String] = []

    // MARK: - Init

    /// Attempts to load the system contextual embedding.
    /// Tries Latin-script model first (covers Czech, Slovak, German, French, etc.),
    /// then falls back to English. If neither is available, all similarity
    /// calls return nil and keyword scoring is used instead.
    func loadIfNeeded() async {
        guard isAvailable == nil else { return }

        // Latin-script model covers all Latin-alphabet languages including Czech.
        // English-only model is a fallback for devices without multilingual assets.
        let model = NLContextualEmbedding(script: .latin)
            ?? NLContextualEmbedding(language: .english)

        guard let model else {
            isAvailable = false
            return
        }

        if model.hasAvailableAssets {
            embedding = model
            isAvailable = true
        } else {
            isAvailable = false
            Task.detached(priority: .utility) {
                try? await model.requestAssets()
            }
        }
    }

    // MARK: - Public API

    /// Returns cosine similarity between two texts, or nil if embeddings
    /// are unavailable. Range: -1.0 ... 1.0 (1.0 = identical meaning).
    func similarity(between a: String, and b: String) async -> Double? {
        await loadIfNeeded()
        guard let vecA = vector(for: a),
              let vecB = vector(for: b) else { return nil }
        return cosineSimilarity(vecA, vecB)
    }

    /// Returns the raw averaged-pooled embedding as Float32 for a
    /// piece of text, or `nil` when the embedding model isn't loaded.
    /// Used by the document Knowledge Base where we persist vectors
    /// to disk and run cosine similarity in bulk; storing as Float
    /// halves the on-disk size compared to Double with no measurable
    /// quality loss for cosine.
    func embeddingVector(for text: String) async -> [Float]? {
        await loadIfNeeded()
        guard let v = vector(for: text) else { return nil }
        return v.map(Float.init)
    }

    /// Batch-scores an array of texts against a query. Returns parallel
    /// array of similarity scores, or nil if embeddings are unavailable.
    func batchSimilarity(
        query: String,
        candidates: [String]
    ) async -> [Double]? {
        await loadIfNeeded()
        guard let queryVec = vector(for: query) else { return nil }

        return candidates.map { candidate in
            if let candidateVec = vector(for: candidate) {
                return cosineSimilarity(queryVec, candidateVec)
            }
            return 0.0
        }
    }

    /// Clears the embedding cache. Call when facts/episodes are modified.
    func invalidateCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Releases the embedding model AND clears the LRU cache. Called
    /// from the memory-warning path so we shed the heaviest piece of
    /// retained state (the contextual embedding model + ~1 MB of
    /// pooled vectors) before iOS reaches for the LLM runtime.
    ///
    /// Idempotent — safe to call repeatedly. The next `loadIfNeeded`
    /// will re-fetch the model assets (which are already on disk
    /// from the first load, so it's cheap).
    func unload() {
        embedding = nil
        isAvailable = nil
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Clears a single entry from the cache.
    func invalidateCache(for content: String) {
        cache.removeValue(forKey: content)
        cacheOrder.removeAll { $0 == content }
    }

    /// Inserts (or refreshes) a cache entry, evicting the least-recently-
    /// used entry when the cache is at capacity. Centralised so every
    /// cache write goes through the same LRU bookkeeping.
    private func cacheStore(_ vector: [Double], for key: String) {
        if cache[key] != nil {
            cacheOrder.removeAll { $0 == key }
        } else if cache.count >= Self.cacheCapacity, let evict = cacheOrder.first {
            cache.removeValue(forKey: evict)
            cacheOrder.removeFirst()
        }
        cache[key] = vector
        cacheOrder.append(key)
    }

    /// Cache read that also bumps the entry to most-recently-used.
    private func cacheLookup(_ key: String) -> [Double]? {
        guard let value = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return value
    }

    // MARK: - Vector computation

    /// Computes a sentence-level embedding by average-pooling token vectors.
    private func vector(for text: String) -> [Double]? {
        // Check cache first
        if let cached = cacheLookup(text) { return cached }

        guard let embedding else { return nil }

        // Detect the dominant language so the embedding model picks the
        // right tokenizer. Hardcoding `.english` for a Latin-script model
        // produces inferior vectors on Czech / German / French content.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage ?? .english

        guard let result = try? embedding.embeddingResult(
            for: text, language: language
        ) else { return nil }

        var sumVector: [Double] = []
        var tokenCount = 0

        result.enumerateTokenVectors(
            in: text.startIndex..<text.endIndex
        ) { data, _ in
            let floats = data.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
            let doubles = floats.map(Double.init)

            if sumVector.isEmpty {
                sumVector = doubles
            } else {
                let limit = min(sumVector.count, doubles.count)
                for i in 0..<limit {
                    sumVector[i] += doubles[i]
                }
            }
            tokenCount += 1
            return true
        }

        guard !sumVector.isEmpty, tokenCount > 0 else { return nil }
        let sum = sumVector

        // Average pool
        let averaged = sum.map { $0 / Double(tokenCount) }

        // Cache the result through the LRU helper so we don't grow
        // unboundedly across long sessions.
        cacheStore(averaged, for: text)

        return averaged
    }

    // MARK: - Math

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }

        var dot = 0.0
        var normA = 0.0
        var normB = 0.0

        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denom = (normA * normB).squareRoot()
        guard denom > 1e-10 else { return 0.0 }
        return dot / denom
    }
}
