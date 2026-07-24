import XCTest
@testable import HomeHub

/// Coverage for `KnowledgeBaseRetrievalService.fuseAndRank` — the pure
/// fuse + cap + classify step extracted from `retrieve(for:)`.
///
/// This is the load-bearing part of hybrid retrieval: it owns the invariant
/// that the dense and lexical rankings share one index space, and it decides
/// each result's `matchKind` and final `rank`. The `retrieve` method itself
/// depends on concrete `KnowledgeBaseStore` / `EmbeddingService` actors, so it
/// cannot be driven with fakes without a DI refactor — extracting this logic
/// is what makes the risky part testable at all.
final class KnowledgeBaseRetrievalFusionTests: XCTestCase {

    private typealias Scored = LexicalRetrieval.Scored
    private typealias Ranked = KnowledgeBaseRetrievalService.RankedResult

    // MARK: - Classification

    func testAgreementIsHybridAndOutranksSingleRankerHits() {
        // Index 1 is in both rankings → hybrid, and RRF rewards the agreement
        // so it should lead. Index 0 (dense-only) and index 7 (lexical-only)
        // are classified by which ranking held them.
        let dense = [Scored(index: 0, score: 0.9), Scored(index: 1, score: 0.8)]
        let lexical = [Scored(index: 1, score: 5), Scored(index: 7, score: 4)]

        let result = KnowledgeBaseRetrievalService.fuseAndRank(
            dense: dense, lexical: lexical, canScoreDense: true, maxChunks: 6
        )

        XCTAssertEqual(result.first, Ranked(index: 1, matchKind: .hybrid, rank: 0))
        XCTAssertEqual(result.first(where: { $0.index == 0 })?.matchKind, .dense)
        XCTAssertEqual(result.first(where: { $0.index == 7 })?.matchKind, .lexical)
    }

    func testRankIsContiguousZeroBasedInOutputOrder() {
        let dense = [Scored(index: 0, score: 0.9)]
        let lexical = [Scored(index: 0, score: 5), Scored(index: 1, score: 4)]

        let result = KnowledgeBaseRetrievalService.fuseAndRank(
            dense: dense, lexical: lexical, canScoreDense: true, maxChunks: 6
        )

        XCTAssertEqual(result.map(\.rank), Array(0..<result.count))
    }

    // MARK: - Lexical-only cap (injection control)

    func testLexicalOnlyMatchesAreCappedWhenDenseIsAvailable() {
        // Three lexical-only candidates (20, 21, 22) plus two hybrids (10, 11).
        // With the default cap of 2, the third lexical-only (22) must be
        // dropped even though it fits within maxChunks — that is the whole
        // point: keyword-spam cannot flood the context past the cap.
        let dense = [Scored(index: 10, score: 0.9), Scored(index: 11, score: 0.8)]
        let lexical = [
            Scored(index: 11, score: 5), Scored(index: 20, score: 4),
            Scored(index: 21, score: 3), Scored(index: 22, score: 2),
            Scored(index: 10, score: 1)
        ]

        let result = KnowledgeBaseRetrievalService.fuseAndRank(
            dense: dense, lexical: lexical, canScoreDense: true, maxChunks: 6
        )

        XCTAssertEqual(result, [
            Ranked(index: 11, matchKind: .hybrid, rank: 0),
            Ranked(index: 10, matchKind: .hybrid, rank: 1),
            Ranked(index: 20, matchKind: .lexical, rank: 2),
            Ranked(index: 21, matchKind: .lexical, rank: 3)
        ])
        XCTAssertFalse(result.contains { $0.index == 22 }, "third lexical-only must be capped out")
    }

    func testHybridAndDenseMatchesAreNeverCapped() {
        // Five hybrids, cap is 2 — but the cap only bites lexical-only matches,
        // so all five hybrids survive (up to maxChunks).
        let indices = [1, 2, 3, 4, 5]
        let dense = indices.map { Scored(index: $0, score: Float(10 - $0)) }
        let lexical = indices.map { Scored(index: $0, score: Float(10 - $0)) }

        let result = KnowledgeBaseRetrievalService.fuseAndRank(
            dense: dense, lexical: lexical, canScoreDense: true, maxChunks: 6, lexicalOnlyCap: 2
        )

        XCTAssertEqual(result.count, 5)
        XCTAssertTrue(result.allSatisfy { $0.matchKind == .hybrid })
    }

    // MARK: - Degraded (embedder unavailable) path

    func testCapIsLiftedWhenDenseScoringUnavailable() {
        // canScoreDense == false: lexical is the ONLY signal, so the cap must
        // not apply — otherwise the fallback that exists to keep retrieval
        // working without an embedder would return at most `lexicalOnlyCap`
        // chunks. All lexical hits come back, all classified `.lexical`.
        let lexical = (0..<5).map { Scored(index: $0, score: Float(5 - $0)) }

        let result = KnowledgeBaseRetrievalService.fuseAndRank(
            dense: [], lexical: lexical, canScoreDense: false, maxChunks: 6, lexicalOnlyCap: 2
        )

        XCTAssertEqual(result.count, 5)
        XCTAssertTrue(result.allSatisfy { $0.matchKind == .lexical })
        XCTAssertEqual(result.map(\.index), [0, 1, 2, 3, 4])
    }

    // MARK: - Bounds

    func testMaxChunksIsRespected() {
        let lexical = (0..<10).map { Scored(index: $0, score: Float(10 - $0)) }

        let result = KnowledgeBaseRetrievalService.fuseAndRank(
            dense: [], lexical: lexical, canScoreDense: false, maxChunks: 3
        )

        XCTAssertEqual(result.count, 3)
    }

    func testZeroMaxChunksReturnsEmpty() {
        let lexical = [Scored(index: 0, score: 1)]
        XCTAssertTrue(
            KnowledgeBaseRetrievalService.fuseAndRank(
                dense: [], lexical: lexical, canScoreDense: false, maxChunks: 0
            ).isEmpty
        )
    }

    func testEmptyRankingsReturnEmpty() {
        XCTAssertTrue(
            KnowledgeBaseRetrievalService.fuseAndRank(
                dense: [], lexical: [], canScoreDense: true, maxChunks: 6
            ).isEmpty
        )
    }
}
