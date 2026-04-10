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
    private var cache: [String: [Double]] = [:]

    // MARK: - Init

    /// Attempts to load the system contextual embedding for English.
    /// Non-throwing: if the model isn't available, `isAvailable` is set
    /// to false and all similarity calls fall back to nil.
    func loadIfNeeded() async {
        guard isAvailable == nil else { return }

        guard let model = NLContextualEmbedding.contextualEmbedding(
            forLanguage: .english
        ) else {
            isAvailable = false
            return
        }

        if model.hasAvailableAssets {
            embedding = model
            isAvailable = true
        } else {
            // Request async download of embedding assets.
            // Until they arrive, similarity calls return nil.
            isAvailable = false
            Task.detached(priority: .utility) { [weak model] in
                try? await model?.requestAssets()
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
    }

    /// Clears a single entry from the cache.
    func invalidateCache(for content: String) {
        cache.removeValue(forKey: content)
    }

    // MARK: - Vector computation

    /// Computes a sentence-level embedding by average-pooling token vectors.
    private func vector(for text: String) -> [Double]? {
        // Check cache first
        if let cached = cache[text] { return cached }

        guard let embedding else { return nil }

        guard let result = try? embedding.embeddingResult(
            for: text, language: .english
        ) else { return nil }

        var sumVector: [Double]?
        var tokenCount = 0

        result.enumerateTokenVectors(
            in: text.startIndex..<text.endIndex
        ) { data, _ in
            let floats = data.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
            let doubles = floats.map(Double.init)

            if sumVector == nil {
                sumVector = doubles
            } else {
                for i in 0..<min(sumVector!.count, doubles.count) {
                    sumVector![i] += doubles[i]
                }
            }
            tokenCount += 1
            return true
        }

        guard let sum = sumVector, tokenCount > 0 else { return nil }

        // Average pool
        let averaged = sum.map { $0 / Double(tokenCount) }

        // Cache the result
        cache[text] = averaged

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
