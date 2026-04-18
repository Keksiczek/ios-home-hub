import XCTest
@testable import HomeHub

/// Unit tests for `ConversationRuntimeSession` and `StreamCacheBox`.
///
/// ## What these tests guard
/// 1. `commonPrefixLength` returns 0 for empty cached tokens.
/// 2. `commonPrefixLength` returns the full length when tokens are identical.
/// 3. `commonPrefixLength` stops at the first mismatch.
/// 4. `commonPrefixLength` is bounded by the shorter of the two arrays.
/// 5. `minReuseRatio` (0.5) gates whether a prefix qualifies for reuse.
/// 6. `StreamCacheBox.finalPromptTokens` defaults to empty and can be set.
/// 7. `ConversationRuntimeSession` is `Equatable` on `conversationID` + tokens.
final class ConversationRuntimeSessionTests: XCTestCase {

    // MARK: - commonPrefixLength

    func testPrefixLengthEmptyCacheReturnsZero() {
        let session = makeSession(cached: [])
        XCTAssertEqual(session.commonPrefixLength(with: [1, 2, 3]), 0)
    }

    func testPrefixLengthEmptyNewTokensReturnsZero() {
        let session = makeSession(cached: [1, 2, 3])
        XCTAssertEqual(session.commonPrefixLength(with: []), 0)
    }

    func testPrefixLengthIdenticalArraysReturnsFullLength() {
        let tokens: [Int32] = [10, 20, 30, 40, 50]
        let session = makeSession(cached: tokens)
        XCTAssertEqual(session.commonPrefixLength(with: tokens), tokens.count)
    }

    func testPrefixLengthStopsAtFirstMismatch() {
        let session = makeSession(cached: [1, 2, 3, 99])
        let result = session.commonPrefixLength(with: [1, 2, 3, 100, 5])
        XCTAssertEqual(result, 3)
    }

    func testPrefixLengthBoundedByShorterArray() {
        // cached has 5 tokens, new has 3 — even if all match, result is 3.
        let session = makeSession(cached: [1, 2, 3, 4, 5])
        XCTAssertEqual(session.commonPrefixLength(with: [1, 2, 3]), 3)
    }

    func testPrefixLengthNoOverlapReturnsZero() {
        let session = makeSession(cached: [100, 200, 300])
        XCTAssertEqual(session.commonPrefixLength(with: [1, 2, 3]), 0)
    }

    // MARK: - minReuseRatio gate

    func testReuseQualifiesWhenPrefixCoversMajority() {
        // 10-token prompt, 6 matching = ratio 0.6 ≥ 0.5 → qualifies
        let session = makeSession(cached: Array(0..<6).map { Int32($0) })
        let newTokens = Array(0..<10).map { Int32($0) }
        let prefixLen = session.commonPrefixLength(with: newTokens)
        let ratio = Double(prefixLen) / Double(newTokens.count)
        XCTAssertGreaterThanOrEqual(ratio, ConversationRuntimeSession.minReuseRatio)
    }

    func testReuseDoesNotQualifyWhenPrefixTooShort() {
        // 10-token prompt, 3 matching = ratio 0.3 < 0.5 → does not qualify
        let session = makeSession(cached: Array(0..<3).map { Int32($0) })
        let newTokens = Array(0..<10).map { Int32($0) }
        let prefixLen = session.commonPrefixLength(with: newTokens)
        let ratio = Double(prefixLen) / Double(newTokens.count)
        XCTAssertLessThan(ratio, ConversationRuntimeSession.minReuseRatio)
    }

    func testMinReuseRatioIsHalf() {
        XCTAssertEqual(ConversationRuntimeSession.minReuseRatio, 0.5)
    }

    // MARK: - StreamCacheBox

    func testCacheBoxDefaultsToEmpty() {
        let box = StreamCacheBox()
        XCTAssertTrue(box.finalPromptTokens.isEmpty)
    }

    func testCacheBoxCanBeWritten() {
        let box = StreamCacheBox()
        box.finalPromptTokens = [1, 2, 3]
        XCTAssertEqual(box.finalPromptTokens, [1, 2, 3])
    }

    func testCacheBoxOverwriteReplacesPrevious() {
        let box = StreamCacheBox()
        box.finalPromptTokens = [1, 2, 3]
        box.finalPromptTokens = [7, 8]
        XCTAssertEqual(box.finalPromptTokens, [7, 8])
    }

    // MARK: - Equatable

    func testSessionEqualityRequiresSameIDAndTokens() {
        let id = UUID()
        let a = ConversationRuntimeSession(conversationID: id, cachedPromptTokens: [1, 2])
        let b = ConversationRuntimeSession(conversationID: id, cachedPromptTokens: [1, 2])
        XCTAssertEqual(a, b)
    }

    func testSessionInequalityOnDifferentTokens() {
        let id = UUID()
        let a = ConversationRuntimeSession(conversationID: id, cachedPromptTokens: [1, 2])
        let b = ConversationRuntimeSession(conversationID: id, cachedPromptTokens: [1, 3])
        XCTAssertNotEqual(a, b)
    }

    func testSessionInequalityOnDifferentID() {
        let a = ConversationRuntimeSession(conversationID: UUID(), cachedPromptTokens: [1, 2])
        let b = ConversationRuntimeSession(conversationID: UUID(), cachedPromptTokens: [1, 2])
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Helpers

    private func makeSession(cached: [Int32]) -> ConversationRuntimeSession {
        ConversationRuntimeSession(conversationID: UUID(), cachedPromptTokens: cached)
    }
}
