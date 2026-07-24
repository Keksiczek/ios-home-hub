import Foundation

/// BM25 lexical scoring over chunk text, plus Reciprocal Rank Fusion for
/// combining a lexical ranking with a dense (embedding) one.
///
/// ## Why this exists
///
/// Two independent reasons, and both matter:
///
/// 1. **Dense retrieval has a blind spot.** Embeddings match on *meaning*, so
///    they reliably miss things that carry meaning only by being the exact
///    string: proper nouns, error codes, model numbers, version strings, rare
///    technical terms. Asking "co říká manuál o chybě E-041" is a query where
///    cosine similarity is close to useless and exact matching is close to
///    perfect. Hybrid retrieval is the standard answer and it needs no model.
///
/// 2. **Dense retrieval can be entirely unavailable.** `EmbeddingService` is
///    backed by `NLContextualEmbedding`, whose assets download separately and
///    can legitimately be missing. Before this file existed, that produced a
///    silent nothing: `KnowledgeBaseRetrievalService.retrieve` returned `[]`
///    with no log, and the model answered every question as if the user's
///    documents did not exist. Lexical scoring turns that from a silent
///    failure into a **degraded but working** path.
///
/// ## Division of labour with dense retrieval
///
/// This scorer deliberately does **not** attempt to handle Czech morphology.
/// Stemming "pracoval" / "pracovní" / "práce" to a common root is exactly what
/// the embedding model is good at, and a hand-rolled Slavic stemmer trades a
/// real risk of false positives — wrong passages injected into the prompt —
/// for a benefit the dense half already provides.
///
/// What it does normalise is **diacritics**, because Czech users routinely type
/// "reklamace" for "reklamacé" and "hlaseni" for "hlášení". That is an input
/// convention, not morphology, and folding it costs nothing.
///
/// So: dense handles meaning and inflection; lexical handles exact and
/// near-exact strings; RRF combines them. Neither is asked to do the other's
/// job.
///
/// ## Why BM25 rather than TF-IDF
///
/// Chunks vary in length (`KBVersions.chunking` targets 1000 chars but real
/// chunks fall short at document boundaries). BM25's `b` term normalises for
/// that, so a short chunk that mentions a term twice does not automatically
/// outrank a long one that discusses it throughout. Plain TF-IDF has no such
/// correction and systematically favours short chunks.
enum LexicalRetrieval {

    /// BM25 term-frequency saturation. 1.2 is the long-standing default from
    /// the TREC experiments; above it, repeated terms keep adding score, below
    /// it a single mention is nearly as good as ten.
    static let k1: Float = 1.2

    /// BM25 length normalisation. 0.75 is the standard default: full
    /// normalisation (1.0) over-penalises long chunks that are genuinely
    /// more informative, none (0.0) lets them win on volume alone.
    static let b: Float = 0.75

    /// A scored document, identified by its index in the input array so the
    /// caller can map back to whatever record it came from without this type
    /// needing to know about `ChunkRecord`.
    struct Scored: Equatable, Sendable {
        let index: Int
        let score: Float
    }

    // MARK: - Tokenisation

    /// Splits on anything that is not a letter or digit, lowercases, and folds
    /// diacritics.
    ///
    /// Unicode-aware by construction: `CharacterSet.alphanumerics` covers
    /// Czech letters, and folding via `.diacriticInsensitive` maps "ě" → "e"
    /// without hand-maintained tables. Single-character tokens are dropped —
    /// they carry almost no discriminative signal and inflate the term counts.
    static func tokenize(_ text: String) -> [String] {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "cs_CZ")
        )
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    // MARK: - Scoring

    /// Ranks `documents` against `query` using BM25.
    ///
    /// Returns every document with a score greater than zero, sorted
    /// descending. Documents sharing no query term are omitted entirely rather
    /// than returned with a zero score — a caller taking `prefix(k)` should get
    /// k *matches*, not k rows padded with non-matches.
    ///
    /// - Complexity: O(total tokens) to tokenise, plus
    ///   O(|queryTerms| × documents) to score. Both terms are small here —
    ///   thousands of chunks, a handful of query terms — so a linear scan
    ///   stays well within budget and avoids maintaining a persistent inverted
    ///   index that would need invalidating alongside the vector store.
    static func score(query: String, documents: [String]) -> [Scored] {
        let queryTerms = Set(tokenize(query))
        guard !queryTerms.isEmpty, !documents.isEmpty else { return [] }

        let tokenized = documents.map(tokenize)
        let lengths = tokenized.map { Float($0.count) }
        let totalLength = lengths.reduce(0, +)
        // Guard against an all-empty corpus: avgdl of 0 would make the length
        // normalisation term NaN and poison every score.
        guard totalLength > 0 else { return [] }
        let avgLength = totalLength / Float(documents.count)

        // Term frequencies per document, restricted to query terms — there is
        // no reason to count words nobody asked about.
        let termFrequencies: [[String: Int]] = tokenized.map { tokens in
            var counts: [String: Int] = [:]
            for token in tokens where queryTerms.contains(token) {
                counts[token, default: 0] += 1
            }
            return counts
        }

        let documentCount = Float(documents.count)
        var scores = [Float](repeating: 0, count: documents.count)

        for term in queryTerms {
            // `filter { }.count` rather than `count(where:)`: the latter is
            // SwiftStdlib 6.0 (iOS 18) and this target deploys to iOS 17.
            let documentFrequency = Float(termFrequencies.filter { $0[term] != nil }.count)
            // A term nobody contains contributes nothing and would make the
            // IDF numerator dominate for no reason.
            guard documentFrequency > 0 else { continue }

            // Standard BM25 IDF with the +1 inside the log, which keeps the
            // value non-negative. The textbook form goes negative for terms
            // present in more than half the corpus, which would let a common
            // word *subtract* from a document's score — a real problem on a
            // small corpus where "faktura" might appear in most chunks.
            let idf = log(1 + (documentCount - documentFrequency + 0.5) / (documentFrequency + 0.5))

            for index in documents.indices {
                guard let rawFrequency = termFrequencies[index][term] else { continue }
                let frequency = Float(rawFrequency)
                let norm = frequency + k1 * (1 - b + b * lengths[index] / avgLength)
                scores[index] += idf * (frequency * (k1 + 1)) / norm
            }
        }

        return scores.enumerated()
            .filter { $0.element > 0 }
            .map { Scored(index: $0.offset, score: $0.element) }
            .sorted { $0.score > $1.score }
    }

    // MARK: - Fusion

    /// Default RRF damping constant. 60 is the value from the original
    /// Cormack et al. paper and is what most implementations use unchanged.
    static let rrfK: Float = 60

    /// Combines two rankings by Reciprocal Rank Fusion.
    ///
    /// RRF scores each item by `Σ 1 / (k + rank)` across the rankings it
    /// appears in. The reason to prefer it over a weighted sum of the raw
    /// scores is that **BM25 and cosine similarity are not on comparable
    /// scales** — cosine is bounded to [-1, 1], BM25 is unbounded and its range
    /// depends on corpus statistics. Any weighted sum would need a
    /// normalisation step whose parameters drift as the corpus grows. RRF only
    /// looks at *positions*, so it needs no tuning and cannot be skewed by one
    /// ranker producing large absolute numbers.
    ///
    /// Items appearing in only one ranking are kept, scored on that ranking
    /// alone. That is deliberate: an exact-match hit the embedder missed is
    /// precisely the case hybrid retrieval exists to rescue.
    static func fuse(
        _ rankings: [[Scored]],
        k: Float = rrfK
    ) -> [Scored] {
        var fused: [Int: Float] = [:]
        for ranking in rankings {
            for (position, scored) in ranking.enumerated() {
                fused[scored.index, default: 0] += 1 / (k + Float(position + 1))
            }
        }
        return fused
            .map { Scored(index: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                // Tie-break on index so the ordering is deterministic. Without
                // it, equal RRF scores would come out in dictionary order,
                // which varies between runs and would make any test asserting
                // on the full ranking intermittently fail.
                lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
            }
    }
}
