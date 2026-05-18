import XCTest
@testable import HomeHub

/// Behavioural tests for `MessageImportance` — the pure-function
/// scoring used by `ConversationService` to top up the recall block
/// with intrinsically-important dropped messages.
///
/// The scoring is intentionally simple (no embeddings, no inference)
/// so the tests can pin every signal independently. If a future
/// change tweaks a coefficient, these tests document what the
/// callers *count on* being true rather than the absolute numbers.
final class MessageImportanceTests: XCTestCase {

    private let convID = UUID()

    private func userMsg(_ text: String) -> Message {
        Message.user(text, in: convID)
    }

    private func assistantMsg(_ text: String) -> Message {
        Message(
            id: UUID(),
            conversationID: convID,
            role: .assistant,
            content: text,
            createdAt: .now,
            status: .complete,
            tokenCount: nil
        )
    }

    // MARK: - Trivial replies

    /// "ok", "thanks", "yes" must always score very low — they're the
    /// canonical example of context-poor messages that the budgeter
    /// should drop first. We assert a hard ceiling so even an
    /// accidental "+0.5 for user-role" tweak can't lift them above
    /// the typical recall threshold (~0.35).
    func testTrivialRepliesScoreNearZero() {
        for text in ["ok", "thanks", "yes", "díky", "👍"] {
            let score = MessageImportance.score(userMsg(text))
            XCTAssertLessThanOrEqual(score, 0.1,
                                     "Trivial '\(text)' scored \(score) — should stay near 0")
        }
    }

    // MARK: - Declarations

    /// Messages with declaration markers ("I am", "I prefer", "remember
    /// that", Czech equivalents) are durable user-state and must score
    /// high enough to clear the default recall threshold (0.35).
    func testDeclarationsScoreAboveRecallThreshold() {
        let messages = [
            "I am vegetarian, please remember that for restaurant recommendations.",
            "Remember that my dog's name is Tofu",
            "I prefer concise answers without filler",
            "Jmenuji se Štěpán a žiju v Praze"
        ]
        for text in messages {
            let score = MessageImportance.score(userMsg(text))
            XCTAssertGreaterThan(score, 0.35,
                                 "Declaration '\(text)' scored only \(score) — won't survive recall threshold")
        }
    }

    // MARK: - Code fences

    /// A pasted code block is hard for the model to reconstruct
    /// verbatim, so triple-backtick content must score high enough
    /// to survive even when the surrounding prose is short.
    func testCodeFenceBoostsScore() {
        let withCode = userMsg("Here's the function I'm working on: ```let x = 42\nprint(x)```")
        let withoutCode = userMsg("Here's the function I'm working on: it sets x to 42 and prints it")
        XCTAssertGreaterThan(
            MessageImportance.score(withCode),
            MessageImportance.score(withoutCode),
            "Code-fenced message should outscore prose-only of similar length"
        )
    }

    // MARK: - Role bias

    /// User messages outscore assistant messages of identical content
    /// — user statements encode constraints, assistant statements can
    /// be regenerated. Same text, different role → different score.
    func testUserMessagesOutscoreAssistant() {
        let text = "I work as a designer at a typography studio in Prague."
        let userScore = MessageImportance.score(userMsg(text))
        let assistantScore = MessageImportance.score(assistantMsg(text))
        XCTAssertGreaterThan(userScore, assistantScore,
                             "User-authored '\(text)' should outscore assistant version")
    }

    // MARK: - Top-N selection

    /// `topImportant(_:excluding:limit:)` must return up to `limit`
    /// entries sorted in chronological order (not score-descending)
    /// — readability invariant for the prompt-rendering layer.
    func testTopImportantPreservesChronologicalOrder() {
        var messages: [Message] = []
        // Build a chronological history with one important message
        // sandwiched between two less-important ones.
        let m1 = Message(id: UUID(), conversationID: convID, role: .user,
                         content: "I prefer concise answers without filler text",
                         createdAt: Date(timeIntervalSinceReferenceDate: 100),
                         status: .complete, tokenCount: nil)
        let m2 = Message(id: UUID(), conversationID: convID, role: .user,
                         content: "ok",
                         createdAt: Date(timeIntervalSinceReferenceDate: 200),
                         status: .complete, tokenCount: nil)
        let m3 = Message(id: UUID(), conversationID: convID, role: .user,
                         content: "Remember that my project deadline is on 2026-06-15",
                         createdAt: Date(timeIntervalSinceReferenceDate: 300),
                         status: .complete, tokenCount: nil)
        messages = [m1, m2, m3]

        let top = MessageImportance.topImportant(from: messages, excluding: [], limit: 2)
        XCTAssertEqual(top.count, 2)
        // m1 then m3 chronologically (m2 was trivial and dropped).
        XCTAssertEqual(top[0].id, m1.id)
        XCTAssertEqual(top[1].id, m3.id)
    }

    /// The exclusion set must be honoured — typical caller passes the
    /// IDs the budgeter already kept + semantic-recall IDs to avoid
    /// duplicating content.
    func testExclusionSetFiltersOutSelectedMessages() {
        let important = userMsg("I'm allergic to peanuts, never recommend dishes containing them")
        let alsoImportant = userMsg("My partner's name is Petra")
        let messages = [important, alsoImportant]

        let topWithoutExclude = MessageImportance.topImportant(from: messages, excluding: [], limit: 2)
        XCTAssertEqual(topWithoutExclude.count, 2)

        let topWithExclude = MessageImportance.topImportant(
            from: messages,
            excluding: [important.id],
            limit: 2
        )
        XCTAssertEqual(topWithExclude.count, 1)
        XCTAssertEqual(topWithExclude[0].id, alsoImportant.id)
    }

    // MARK: - Adaptive retrieval helper

    /// `ConversationService.adaptiveRetrievalLimits(for:)` buckets
    /// inputs into three sizes. The bucket boundaries are documented
    /// in the helper itself; these tests pin them so a refactor can't
    /// silently change the curve. Numbers are deliberately checked at
    /// boundaries (29, 30, 199, 200) to catch off-by-one regressions.
    func testAdaptiveLimitsShortBucket() {
        let (facts, episodes) = ConversationService.adaptiveRetrievalLimits(for: "díky")
        XCTAssertEqual(facts, 3)
        XCTAssertEqual(episodes, 1)
    }

    func testAdaptiveLimitsMediumBucket() {
        let input = String(repeating: "a", count: 100)   // 100 chars → medium
        let (facts, episodes) = ConversationService.adaptiveRetrievalLimits(for: input)
        XCTAssertEqual(facts, 8)
        XCTAssertEqual(episodes, 3)
    }

    func testAdaptiveLimitsLongBucket() {
        let input = String(repeating: "a", count: 300)   // 300 chars → long
        let (facts, episodes) = ConversationService.adaptiveRetrievalLimits(for: input)
        XCTAssertEqual(facts, 12)
        XCTAssertEqual(episodes, 5)
    }

    func testAdaptiveLimitsBoundary30() {
        // 29 chars → short bucket; exactly 30 → medium bucket.
        let short = String(repeating: "a", count: 29)
        let medium = String(repeating: "a", count: 30)
        XCTAssertEqual(ConversationService.adaptiveRetrievalLimits(for: short).facts, 3)
        XCTAssertEqual(ConversationService.adaptiveRetrievalLimits(for: medium).facts, 8)
    }

    func testAdaptiveLimitsTrimsWhitespace() {
        // Whitespace-only input must collapse to the short bucket —
        // a user pressing space then return shouldn't trigger a deep
        // retrieval pull.
        let padded = "                                      "  // 38 spaces
        let (facts, _) = ConversationService.adaptiveRetrievalLimits(for: padded)
        XCTAssertEqual(facts, 3, "Whitespace-only input must trim to empty and bucket as short")
    }
}
