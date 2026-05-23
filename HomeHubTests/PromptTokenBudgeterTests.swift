import XCTest
@testable import HomeHub

/// Unit tests for `HeuristicTokenEstimator`, `PromptTokenBudgeter`,
/// and `PromptBudgetReport`.
///
/// ## What these tests guard
/// 1. `HeuristicTokenEstimator` returns plausible counts per script class.
/// 2. Empty input never crashes and returns 0.
/// 3. `PromptTokenBudgeter.trimHistory` uses anchor + recency trimming:
///    always keeps the first 2 messages (anchors) and fills remaining
///    budget with the most-recent messages. Middle messages are dropped.
/// 4. `PromptBudgetReport` derived properties (totalPromptTokens, summary)
///    are consistent with the sections array.
/// 5. The budgeter accounts for per-message overhead in the trim calculation.
final class PromptTokenBudgeterTests: XCTestCase {

    // MARK: - HeuristicTokenEstimator — empty / trivial

    func testEmptyStringReturnsZero() {
        XCTAssertEqual(HeuristicTokenEstimator().tokens(in: ""), 0)
    }

    func testSingleSpaceIsAtLeastOneToken() {
        XCTAssertGreaterThanOrEqual(HeuristicTokenEstimator().tokens(in: " "), 1)
    }

    // MARK: - HeuristicTokenEstimator — ASCII English

    func testASCIIEnglishIsCheaperThanOneTokenPerChar() {
        // "Hello world" = 11 chars. At 0.25 tok/char → ceil(2.75) = 3 tokens.
        // Any plausible result must be well below 11.
        let count = HeuristicTokenEstimator().tokens(in: "Hello world")
        XCTAssertLessThan(count, 11, "ASCII text must be cheaper than 1 token/char")
        XCTAssertGreaterThan(count, 0)
    }

    func testASCIIProseScalesLinearlyWithLength() {
        let estimator = HeuristicTokenEstimator()
        let short = estimator.tokens(in: String(repeating: "a", count: 100))
        let long  = estimator.tokens(in: String(repeating: "a", count: 400))
        // Quadrupling the input should roughly quadruple the token count.
        XCTAssertGreaterThan(long, short * 2,
            "400 'a' chars should yield considerably more tokens than 100")
    }

    // MARK: - HeuristicTokenEstimator — CJK

    func testCJKCharactersAreOneTokenEach() {
        // 10 CJK Unified Ideograph characters — each is ~1 token.
        let cjk = String(repeating: "\u{4E2D}", count: 10) // 中×10
        let count = HeuristicTokenEstimator().tokens(in: cjk)
        // Should be close to 10; allow ±2 for rounding.
        XCTAssertGreaterThanOrEqual(count, 8)
        XCTAssertLessThanOrEqual(count, 12)
    }

    func testCJKIsMoreExpensiveThanASCII() {
        let estimator = HeuristicTokenEstimator()
        let ascii = estimator.tokens(in: String(repeating: "a", count: 20))
        let cjk   = estimator.tokens(in: String(repeating: "\u{4E2D}", count: 20))
        XCTAssertGreaterThan(cjk, ascii,
            "20 CJK chars should cost more tokens than 20 ASCII letters")
    }

    // MARK: - HeuristicTokenEstimator — mixed content

    func testCodeSnippetIsMoreExpensiveThanProseOfSameLength() {
        // Code has lots of ASCII punctuation which is more expensive than letters.
        let prose = "hello world this is a test sentence for benchmarking purposes here"
        let code  = "func foo() { return bar.baz(x: 1, y: 2) ?? nil } // comment here"
        XCTAssertEqual(prose.count, code.count, "Strings must be same length for fair comparison")
        let estimator = HeuristicTokenEstimator()
        XCTAssertGreaterThanOrEqual(estimator.tokens(in: code), estimator.tokens(in: prose),
            "Code with punctuation should not be cheaper than plain prose")
    }

    // MARK: - PromptTokenBudgeter — tokensForMessage

    func testTokesForMessageIncludesOverhead() {
        let profile = ModelCapabilityProfile.llama   // overhead = 7
        let budgeter = PromptTokenBudgeter(profile: profile)
        let content = "Hello"
        let raw = budgeter.tokens(in: content)
        let withOverhead = budgeter.tokensForMessage(content: content)
        XCTAssertEqual(withOverhead, raw + 7,
            "tokensForMessage must add messageTokenOverhead (7 for llama)")
    }

    // MARK: - PromptTokenBudgeter — trimHistory

    func testTrimHistoryEmptyInputReturnsEmpty() {
        let budgeter = PromptTokenBudgeter(profile: .default)
        let result = budgeter.trimHistory([])
        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertEqual(result.dropped, 0)
    }

    func testTrimHistoryKeepsAllWhenUnderBudget() {
        // 3 short messages — total cost well under any profile's budget.
        let messages = makeMessages(count: 3, charLength: 10)
        let budgeter = PromptTokenBudgeter(profile: .llama)
        let result = budgeter.trimHistory(messages)
        XCTAssertEqual(result.kept.count, 3)
        XCTAssertEqual(result.dropped, 0)
    }

    func testTrimHistoryPreservesAnchorsAndRecentMessages() {
        // 20 messages × 400 ASCII chars. At 0.25 tok/char → ~100 tokens body
        // + 7 overhead (llama) = ~107 tokens/msg. Budget 1400 → ~13 messages.
        let messages = makeMessages(count: 20, charLength: 400)
        let budgeter = PromptTokenBudgeter(profile: .llama)
        let result = budgeter.trimHistory(messages)

        XCTAssertLessThan(result.kept.count, 20, "Should have trimmed some messages")
        XCTAssertGreaterThan(result.kept.count, 0, "Should have kept some messages")
        XCTAssertEqual(result.dropped, messages.count - result.kept.count)

        // Anchor invariant: the first 2 messages must always be kept.
        XCTAssertGreaterThanOrEqual(result.kept.count, 2, "Must keep at least the 2 anchors")
        XCTAssertEqual(result.kept[0].id, messages[0].id, "First anchor must be messages[0]")
        XCTAssertEqual(result.kept[1].id, messages[1].id, "Second anchor must be messages[1]")

        // Recency invariant: messages after the anchors must be a suffix
        // of messages[2...], i.e. the most-recent non-anchor messages.
        let recentKept = Array(result.kept.dropFirst(2))
        if !recentKept.isEmpty {
            let tail = Array(messages.dropFirst(2).suffix(recentKept.count))
            XCTAssertEqual(recentKept.map(\.id), tail.map(\.id),
                "Non-anchor kept messages must be the most-recent tail of messages[2...]")
        }
    }

    func testTrimHistoryDropsOldestFirst() {
        // Legacy alias — delegates to the anchor test so old test names still pass.
        testTrimHistoryPreservesAnchorsAndRecentMessages()
    }

    func testTrimHistoryNeverExceedsBudget() {
        // 30 messages × 300 chars, default profile (budget 1000, overhead 5).
        // Each msg ≈ 75 + 5 = 80 tokens; total 2 400 >> 1 000, so trimming fires.
        // Anchor-first: keeps m0, m1; fills tail; drops m2…m{k} from the middle.
        let messages = makeMessages(count: 30, charLength: 300)
        let profile = ModelCapabilityProfile.default
        let budgeter = PromptTokenBudgeter(profile: profile)
        let result = budgeter.trimHistory(messages)

        // 1. Budget not exceeded.
        let totalTokens = result.kept.reduce(0) {
            $0 + budgeter.tokensForMessage(content: $1.content)
        }
        XCTAssertLessThanOrEqual(totalTokens, profile.safeHistoryTokenBudget,
            "Token cost of kept messages must not exceed the budget")

        // 2. Anchor invariant: the first two messages must always survive.
        XCTAssertGreaterThanOrEqual(result.kept.count, 2,
            "At least the 2 anchors must be kept")
        XCTAssertEqual(result.kept[0].id, messages[0].id,
            "First anchor (m0) must be kept")
        XCTAssertEqual(result.kept[1].id, messages[1].id,
            "Second anchor (m1) must be kept")

        // 3. Dropped messages must NOT include either anchor — only middle
        //    messages (between the anchors and the recent tail) should fall.
        let keptIDs = Set(result.kept.map(\.id))
        let anchorIDs = Set(messages.prefix(2).map(\.id))
        let droppedAnchorCount = anchorIDs.subtracting(keptIDs).count
        XCTAssertEqual(droppedAnchorCount, 0,
            "Anchors m0/m1 must never be dropped — only middle messages should fall")
    }

    func testTighterBudgetKeepsFewerMessages() {
        // 20 messages × 400 chars.
        // Llama (budget 1 400, overhead 7): each ≈ 107 tok → trims to ~13 (2 anchors + 11 recent).
        // Phi   (budget 1 200, overhead 5): each ≈ 105 tok → trims to ~11 (2 anchors + 9 recent).
        let messages = makeMessages(count: 20, charLength: 400)
        let llamaBudgeter = PromptTokenBudgeter(profile: .llama)
        let phiBudgeter   = PromptTokenBudgeter(profile: .phi)

        let llamaResult = llamaBudgeter.trimHistory(messages)
        let phiResult   = phiBudgeter.trimHistory(messages)

        // 1. Larger budget → keeps at least as many messages.
        XCTAssertGreaterThanOrEqual(llamaResult.kept.count, phiResult.kept.count,
            "Llama's larger budget should keep at least as many messages as Phi's")

        // 2. Both profiles must honour the anchor+recency structure.
        for (result, label) in [(llamaResult, "llama"), (phiResult, "phi")] {
            // 2a. Anchors present.
            XCTAssertGreaterThanOrEqual(result.kept.count, 2,
                "\(label): must keep at least 2 anchors")
            XCTAssertEqual(result.kept[0].id, messages[0].id,
                "\(label): first anchor must be messages[0]")
            XCTAssertEqual(result.kept[1].id, messages[1].id,
                "\(label): second anchor must be messages[1]")

            // 2b. Non-anchor kept messages are the most-recent tail of messages[2...].
            let recentKept = Array(result.kept.dropFirst(2))
            if !recentKept.isEmpty {
                let expectedTail = Array(messages.dropFirst(2).suffix(recentKept.count))
                XCTAssertEqual(recentKept.map(\.id), expectedTail.map(\.id),
                    "\(label): non-anchor kept messages must be the most-recent tail")
            }
        }
    }

    func testTrimHistoryPreservesOriginalOrder() {
        // Use enough messages + chars that trimming actually fires, so the test
        // isn't trivially satisfied by the "all fit" fast path.
        // 15 messages × 400 chars, llama (budget 1 400, overhead 7).
        // Each ≈ 107 tokens; total ~1 605 > 1 400 → trimming fires.
        let messages = makeMessages(count: 15, charLength: 400)
        let budgeter = PromptTokenBudgeter(profile: .llama)
        let result = budgeter.trimHistory(messages)

        XCTAssertLessThan(result.kept.count, messages.count,
            "Trimming must have fired — all messages must not have fit")

        // Kept messages must appear in the same relative order as in the input
        // (they form an order-preserving subsequence). With anchor trimming the
        // result is [m0, m1, …recent…], which is NOT necessarily messages.suffix(k),
        // but the relative order of the kept IDs must still match the original.
        let keptIDs   = result.kept.map(\.id)
        let originalIDs = messages.map(\.id)
        var cursor = originalIDs.startIndex
        for id in keptIDs {
            guard let idx = originalIDs[cursor...].firstIndex(of: id) else {
                XCTFail("Kept message \(id) not found in original array at or after index \(cursor)")
                return
            }
            cursor = originalIDs.index(after: idx)
        }
        // If we reach here, every kept ID appeared in the original order.
    }

    // MARK: - PromptBudgetReport

    func testTotalPromptTokensIsSumOfSections() {
        let report = PromptBudgetReport(
            family: "llama",
            mode: .chat,
            sections: [
                .init(name: "system",     tokens: 300),
                .init(name: "history",    tokens: 700),
                .init(name: "user_input", tokens: 15)
            ],
            historyMessagesKept: 5,
            historyMessagesDropped: 2,
            generationReserveTokens: 512
        )
        XCTAssertEqual(report.totalPromptTokens, 1015)
    }

    func testSummaryContainsAllKeyFields() {
        let report = PromptBudgetReport(
            family: "qwen",
            mode: .chat,
            sections: [
                .init(name: "system", tokens: 200),
                .init(name: "history", tokens: 500)
            ],
            historyMessagesKept: 4,
            historyMessagesDropped: 1,
            generationReserveTokens: 512
        )
        let s = report.summary
        XCTAssertTrue(s.contains("qwen"))
        XCTAssertTrue(s.contains("chat"))
        XCTAssertTrue(s.contains("system"))
        XCTAssertTrue(s.contains("history"))
        XCTAssertTrue(s.contains("kept: 4"))
        XCTAssertTrue(s.contains("dropped: 1"))
        XCTAssertTrue(s.contains("reserve: 512"))
        XCTAssertTrue(s.contains("total prompt: 700"))
    }

    func testEmptyReportHasZeroTotal() {
        let report = PromptBudgetReport(
            family: "",
            mode: .summarization,
            sections: [],
            historyMessagesKept: 0,
            historyMessagesDropped: 0,
            generationReserveTokens: 512
        )
        XCTAssertEqual(report.totalPromptTokens, 0)
    }

    // MARK: - Helpers

    private func makeMessages(count: Int, charLength: Int) -> [Message] {
        let convID = UUID()
        return (0..<count).map { i in
            Message(
                id: UUID(),
                conversationID: convID,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: String(repeating: "x", count: charLength),
                createdAt: Date(timeIntervalSinceNow: Double(i)),
                status: .complete,
                tokenCount: nil
            )
        }
    }
}
