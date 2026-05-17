import XCTest
@testable import HomeHub

/// Tests the memoised path `TokenEstimator.cachedTokens(in:)` that
/// backs the chat context-fill banner. The hot-path correctness
/// requirement: the cached entry must invalidate when content length
/// changes (the streaming-message case) while staying intact for
/// finished messages whose content is frozen.
final class TokenEstimatorCacheTests: XCTestCase {

    private func makeMessage(id: UUID = UUID(), content: String) -> Message {
        Message(
            id: id,
            conversationID: UUID(),
            role: .user,
            content: content,
            createdAt: .now,
            status: .complete,
            tokenCount: nil,
            attachments: nil
        )
    }

    func testCachedTokens_AgreesWithUncachedForSingleMessage() {
        let msg = makeMessage(content: "Hello world, this is a normal sentence.")
        let uncached = TokenEstimator.tokens(in: [msg])
        let cached = TokenEstimator.cachedTokens(in: [msg])
        XCTAssertEqual(uncached, cached,
            "Cached total must match the canonical uncached count")
    }

    func testCachedTokens_InvalidatesOnContentChange() {
        let id = UUID()
        let short = makeMessage(id: id, content: "Hi.")
        let long  = makeMessage(id: id, content: String(repeating: "Hello world. ", count: 20))

        let firstCount = TokenEstimator.cachedTokens(in: [short])
        let secondCount = TokenEstimator.cachedTokens(in: [long])

        XCTAssertNotEqual(firstCount, secondCount,
            "Cache must invalidate when the same message ID has different content")
        XCTAssertEqual(
            secondCount,
            TokenEstimator.tokens(in: [long]),
            "Second call must reflect the new content, not stale cached value"
        )
    }

    func testCachedTokens_ReusesEntryWhenContentIdentical() {
        let id = UUID()
        let msg = makeMessage(id: id, content: "Static, never-changing prompt.")
        // First call populates the cache.
        let firstCount = TokenEstimator.cachedTokens(in: [msg])
        // Second call must produce the same number — implicitly via
        // cache lookup; we don't have a hit-count probe but we can
        // assert identity of result for an idempotent content.
        let secondCount = TokenEstimator.cachedTokens(in: [msg])
        XCTAssertEqual(firstCount, secondCount)
    }

    func testCachedTokens_SumsCorrectlyAcrossMixedMessages() {
        let messages: [Message] = [
            makeMessage(content: "First."),
            makeMessage(content: "Second message is a little longer."),
            makeMessage(content: ""),
            makeMessage(content: "Final."),
        ]
        let cached = TokenEstimator.cachedTokens(in: messages)
        let uncached = TokenEstimator.tokens(in: messages)
        XCTAssertEqual(cached, uncached)
    }

    func testContextFill_UsesCachedPath() {
        let messages = (0..<5).map { i in
            makeMessage(content: "Message \(i) with a little body text.")
        }
        let fill = TokenEstimator.contextFill(messages: messages, contextLength: 2048)
        XCTAssertGreaterThan(fill, 0.0)
        XCTAssertLessThanOrEqual(fill, 1.0)
    }

    func testContextFill_ReturnsZeroForInvalidBudget() {
        let messages = [makeMessage(content: "Anything")]
        XCTAssertEqual(TokenEstimator.contextFill(messages: messages, contextLength: 0), 0)
        XCTAssertEqual(TokenEstimator.contextFill(messages: messages, contextLength: -10), 0)
    }
}
