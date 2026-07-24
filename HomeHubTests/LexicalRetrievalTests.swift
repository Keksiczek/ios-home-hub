import XCTest
@testable import HomeHub

/// Coverage for `LexicalRetrieval` — the BM25 scorer and the RRF fusion that
/// combines it with dense retrieval.
///
/// Everything here is a pure function over strings, so these tests need no
/// model, no network, no simulator state and no embedding assets. That is the
/// point: this component exists precisely to keep working when the embedding
/// backend does not, so its own coverage must not depend on the thing it is
/// insuring against.
final class LexicalRetrievalTests: XCTestCase {

    // MARK: - Tokenisation

    func testTokenizeFoldsDiacriticsAndCase() {
        // Czech users routinely type without diacritics. "hlaseni" must reach
        // the same token as "hlášení" or exact-match retrieval fails on the
        // most common real input.
        XCTAssertEqual(LexicalRetrieval.tokenize("Hlášení"), ["hlaseni"])
        XCTAssertEqual(LexicalRetrieval.tokenize("PŘÍKAZ"), LexicalRetrieval.tokenize("prikaz"))
    }

    func testTokenizeSplitsOnPunctuationAndDropsSingleCharacters() {
        XCTAssertEqual(
            LexicalRetrieval.tokenize("chyba E-041, viz manual."),
            ["chyba", "041", "viz", "manual"]
        )
    }

    // MARK: - BM25 scoring

    func testExactTermMatchOutranksUnrelatedText() {
        // The case dense retrieval is bad at: an alphanumeric code carries
        // meaning only by being the exact string.
        let documents = [
            "Obecný úvod do fungování zařízení a jeho běžné údržby.",
            "Chyba E-041 znamená přehřátí kompresoru. Vypněte přístroj.",
            "Popis dodacích podmínek a reklamačního řádu."
        ]
        let results = LexicalRetrieval.score(query: "co znamená chyba E-041", documents: documents)

        XCTAssertEqual(results.first?.index, 1)
    }

    func testNonMatchingDocumentsAreOmittedNotZeroScored() {
        // A caller taking prefix(k) must get k MATCHES, not k rows padded with
        // documents that share no query term.
        let documents = [
            "Kompresor a jeho údržba.",
            "Zcela nesouvisející text o zahradě."
        ]
        let results = LexicalRetrieval.score(query: "kompresor", documents: documents)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.index, 0)
    }

    func testEmptyQueryAndEmptyCorpusReturnEmpty() {
        XCTAssertTrue(LexicalRetrieval.score(query: "", documents: ["cokoliv"]).isEmpty)
        XCTAssertTrue(LexicalRetrieval.score(query: "dotaz", documents: []).isEmpty)
    }

    func testAllEmptyCorpusDoesNotProduceNaN() {
        // Regression guard: average document length of zero would make BM25's
        // length-normalisation term NaN, and NaN sorts unpredictably — the
        // ranking would be garbage rather than empty.
        let results = LexicalRetrieval.score(query: "dotaz", documents: ["", "", ""])
        XCTAssertTrue(results.isEmpty)
    }

    func testLengthNormalisationDoesNotLetLongDocumentsWinOnVolume() {
        // The reason BM25 is used instead of raw TF-IDF. Both documents
        // mention the term; the short focused one should not be buried by a
        // long one that merely repeats it while discussing everything else.
        let focused = "Reklamace se podává do 14 dnů."
        let padded = "Reklamace. " + String(repeating: "Nesouvisející výplňový text. ", count: 40)

        let results = LexicalRetrieval.score(query: "reklamace", documents: [padded, focused])
        XCTAssertEqual(results.first?.index, 1, "the focused chunk should outrank the padded one")
    }

    func testCommonTermNeverContributesNegativeScore() {
        // Textbook BM25 IDF goes negative once a term appears in more than half
        // the corpus, which on a small corpus would let a common word SUBTRACT
        // from a document's score. The +1 inside the log prevents that.
        let documents = [
            "faktura jedna", "faktura dva", "faktura tri", "faktura ctyri"
        ]
        let results = LexicalRetrieval.score(query: "faktura", documents: documents)

        XCTAssertEqual(results.count, 4)
        for result in results {
            XCTAssertGreaterThan(result.score, 0, "IDF must stay non-negative for common terms")
        }
    }

    // MARK: - Reciprocal Rank Fusion

    func testFusionRewardsAgreementBetweenRankings() {
        // Index 2 is ranked first by one ranker and second by the other; index
        // 0 is first in one and absent from the other. Agreement should win.
        let dense: [LexicalRetrieval.Scored] = [
            .init(index: 0, score: 0.9), .init(index: 2, score: 0.8)
        ]
        let lexical: [LexicalRetrieval.Scored] = [
            .init(index: 2, score: 12.0), .init(index: 5, score: 3.0)
        ]

        let fused = LexicalRetrieval.fuse([dense, lexical])
        XCTAssertEqual(fused.first?.index, 2)
    }

    func testFusionKeepsItemsFoundByOnlyOneRanker() {
        // The whole point of hybrid retrieval: an exact-match hit the embedder
        // missed must survive fusion rather than be filtered out for lacking
        // dense support.
        let dense: [LexicalRetrieval.Scored] = [.init(index: 0, score: 0.9)]
        let lexical: [LexicalRetrieval.Scored] = [.init(index: 7, score: 20.0)]

        let fused = LexicalRetrieval.fuse([dense, lexical])
        XCTAssertEqual(Set(fused.map(\.index)), [0, 7])
    }

    func testFusionIsScaleInvariant() {
        // RRF's reason for existing: BM25 scores are unbounded while cosine is
        // bounded to [-1, 1]. Multiplying one ranker's raw scores by 1000 must
        // not change the outcome, because only positions are consulted.
        let dense: [LexicalRetrieval.Scored] = [
            .init(index: 3, score: 0.71), .init(index: 1, score: 0.44)
        ]
        let lexical: [LexicalRetrieval.Scored] = [
            .init(index: 1, score: 18.2), .init(index: 3, score: 4.1)
        ]
        let inflated = lexical.map {
            LexicalRetrieval.Scored(index: $0.index, score: $0.score * 1000)
        }

        XCTAssertEqual(
            LexicalRetrieval.fuse([dense, lexical]).map(\.index),
            LexicalRetrieval.fuse([dense, inflated]).map(\.index)
        )
    }

    func testFusionOrderingIsDeterministic() {
        // Equal RRF scores must not come out in dictionary order, which varies
        // between runs and would make ranking assertions intermittently fail.
        let a: [LexicalRetrieval.Scored] = [.init(index: 4, score: 1)]
        let b: [LexicalRetrieval.Scored] = [.init(index: 2, score: 1)]

        let first = LexicalRetrieval.fuse([a, b]).map(\.index)
        for _ in 0..<20 {
            XCTAssertEqual(LexicalRetrieval.fuse([a, b]).map(\.index), first)
        }
        XCTAssertEqual(first, [2, 4], "ties break on ascending index")
    }
}
