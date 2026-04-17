import XCTest
@testable import HomeHub

/// Unit tests for `HeuristicTokenEstimator`, `PromptTokenBudgeter`,
/// and `PromptBudgetReport`.
///
/// ## What these tests guard
/// 1. `HeuristicTokenEstimator` returns plausible counts per script class.
/// 2. Empty input never crashes and returns 0.
/// 3. `PromptTokenBudgeter.trimHistory` drops the oldest messages first
///    and never exceeds the budget.
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

    func testTrimHistoryDropsOldestFirst() {
        // 20 messages × 400 ASCII chars. At 0.25 tok/char → ~100 tokens body
        // + 7 overhead (llama) = ~107 tokens/msg. Budget 1400 → ~13 messages.
        let messages = makeMessages(count: 20, charLength: 400)
        let budgeter = PromptTokenBudgeter(profile: .llama)
        let result = budgeter.trimHistory(messages)

        XCTAssertLessThan(result.kept.count, 20, "Should have trimmed some messages")
        XCTAssertGreaterThan(result.kept.count, 0, "Should have kept some messages")

        // Kept messages must be a suffix of the original list (newest-first retention).
        let expectedSuffix = Array(messages.suffix(result.kept.count))
        XCTAssertEqual(result.kept.map(\.id), expectedSuffix.map(\.id),
            "Kept messages must be the most-recent ones, in original order")

        XCTAssertEqual(result.dropped, messages.count - result.kept.count)
    }

    func testTrimHistoryNeverExceedsBudget() {
        let messages = makeMessages(count: 30, charLength: 300)
        let profile = ModelCapabilityProfile.default
        let budgeter = PromptTokenBudgeter(profile: profile)
        let result = budgeter.trimHistory(messages)

        let totalTokens = result.kept.reduce(0) {
            $0 + budgeter.tokensForMessage(content: $1.content)
        }
        XCTAssertLessThanOrEqual(totalTokens, profile.safeHistoryTokenBudget,
            "Token cost of kept messages must not exceed the budget")
    }

    func testTighterBudgetKeepsFewerMessages() {
        let messages = makeMessages(count: 20, charLength: 400)
        let llamaBudgeter = PromptTokenBudgeter(profile: .llama)
        let phiBudgeter   = PromptTokenBudgeter(profile: .phi)

        let llamaResult = llamaBudgeter.trimHistory(messages)
        let phiResult   = phiBudgeter.trimHistory(messages)

        XCTAssertGreaterThanOrEqual(llamaResult.kept.count, phiResult.kept.count,
            "Llama's larger budget should keep at least as many messages as Phi's")
    }

    func testTrimHistoryPreservesOriginalOrder() {
        let messages = makeMessages(count: 5, charLength: 50)
        let budgeter = PromptTokenBudgeter(profile: .llama)
        let result = budgeter.trimHistory(messages)
        // Kept messages must appear in the same relative order as the input.
        let suffix = Array(messages.suffix(result.kept.count))
        XCTAssertEqual(result.kept.map(\.id), suffix.map(\.id))
    }

    // MARK: - PromptBudgetReport

    func testTotalPromptTokensIsSumOfSections() {
        let report = PromptBudgetReport(
            family: "llama",
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
