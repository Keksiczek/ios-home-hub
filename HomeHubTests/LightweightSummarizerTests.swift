import XCTest
@testable import HomeHub

/// Coverage for `LightweightSummarizer` — the LLM-free extractive
/// fallback wired into `ConversationService.maybeSummarizeOlderHalf`.
final class LightweightSummarizerTests: XCTestCase {

    private func makeMessage(role: Message.Role, _ content: String) -> Message {
        Message(
            id: UUID(),
            conversationID: UUID(),
            role: role,
            content: content,
            createdAt: .now,
            status: .complete,
            tokenCount: nil,
            attachments: nil,
            bookmarked: nil,
            finishReason: nil
        )
    }

    // MARK: - Anchor + tail extraction

    func testReturnsNilForEmptyInput() {
        XCTAssertNil(LightweightSummarizer.summarize(messages: []))
    }

    func testReturnsNilWhenNoUserMessages() {
        let messages = [
            makeMessage(role: .assistant, "Hi! How can I help?"),
            makeMessage(role: .assistant, "Still here…")
        ]
        XCTAssertNil(LightweightSummarizer.summarize(messages: messages))
    }

    func testIncludesAutoRecapHeader() {
        // `[Auto-recap]` prefix is the parse anchor distinguishing
        // this extractive fallback from the LLM-backed paragraph.
        let messages = [makeMessage(role: .user, "Hello.")]
        let summary = LightweightSummarizer.summarize(messages: messages)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.hasPrefix("[Auto-recap]") ?? false)
    }

    func testIncludesFirstUserMessageAsAnchor() {
        let messages = [
            makeMessage(role: .user, "Help me set up a HomeKit scene."),
            makeMessage(role: .assistant, "Sure, which devices?")
        ]
        let summary = LightweightSummarizer.summarize(messages: messages) ?? ""
        XCTAssertTrue(summary.contains("User opened with:"))
        XCTAssertTrue(summary.contains("HomeKit scene"))
    }

    func testIncludesRecentUserFollowUps() {
        let messages = [
            makeMessage(role: .user,      "How do I make tea?"),
            makeMessage(role: .assistant, "Boil water."),
            makeMessage(role: .user,      "What temperature?"),
            makeMessage(role: .assistant, "About 95°C for black tea."),
            makeMessage(role: .user,      "How long should I steep it?")
        ]
        let summary = LightweightSummarizer.summarize(messages: messages) ?? ""
        XCTAssertTrue(summary.contains("How do I make tea?"))
        XCTAssertTrue(summary.contains("What temperature?"))
        XCTAssertTrue(summary.contains("How long should I steep it?"))
    }

    func testSkipsEmptyAndWhitespaceContent() {
        let messages = [
            makeMessage(role: .user, "First real question."),
            makeMessage(role: .user, "   \n  "),
            makeMessage(role: .user, ""),
            makeMessage(role: .user, "Second real question.")
        ]
        let summary = LightweightSummarizer.summarize(messages: messages) ?? ""
        XCTAssertTrue(summary.contains("First real question."))
        XCTAssertTrue(summary.contains("Second real question."))
        XCTAssertFalse(summary.contains("User then asked: \"\""))
    }

    func testSkipsSystemMessages() {
        let messages = [
            makeMessage(role: .system,    "You are a helpful assistant."),
            makeMessage(role: .user,      "User intent."),
            makeMessage(role: .assistant, "OK.")
        ]
        let summary = LightweightSummarizer.summarize(messages: messages) ?? ""
        XCTAssertFalse(summary.contains("helpful assistant"))
        XCTAssertTrue(summary.contains("User intent."))
    }

    // MARK: - Byte-cap enforcement

    func testTruncatesIndividualItemsAtByteCap() {
        let huge = String(repeating: "lorem ipsum dolor sit amet ", count: 60)
        let messages = [makeMessage(role: .user, huge)]
        let summary = LightweightSummarizer.summarize(
            messages: messages,
            perItemByteCap: 80
        ) ?? ""
        XCTAssertTrue(summary.contains("…"))
        XCTAssertLessThan(summary.utf8.count, 200)
    }

    func testDropsTailItemsBeyondTotalCap() {
        let messages = (0..<5).map {
            makeMessage(role: .user, "Question number \($0) " + String(repeating: "x", count: 150))
        }
        let summary = LightweightSummarizer.summarize(
            messages: messages,
            perItemByteCap: 200,
            totalByteCap: 300,
            tailUserMessages: 4
        ) ?? ""
        XCTAssertLessThanOrEqual(summary.utf8.count, 350)
        XCTAssertTrue(summary.contains("User opened with:"))
        // Last tail item almost certainly doesn't fit inside 300 bytes.
        XCTAssertFalse(summary.contains("Question number 4"))
    }

    func testAnchorIsPreservedEvenAboveTotalCap() {
        // Anchor alone exceeds totalByteCap — still included because a
        // one-bullet recap beats an empty recap.
        let bigAnchor = String(repeating: "topic ", count: 80)
        let messages = [makeMessage(role: .user, bigAnchor)]
        let summary = LightweightSummarizer.summarize(
            messages: messages,
            perItemByteCap: 500,
            totalByteCap: 50
        )
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("User opened with:") ?? false)
    }

    // MARK: - Tail size

    func testTailSizeRespectsParameter() {
        let messages = (0..<6).map {
            makeMessage(role: .user, "msg \($0)")
        }
        let summary = LightweightSummarizer.summarize(
            messages: messages,
            tailUserMessages: 2
        ) ?? ""
        let bulletCount = summary.components(separatedBy: "User then asked:").count - 1
        XCTAssertEqual(bulletCount, 2)
        XCTAssertTrue(summary.contains("msg 5"))
        XCTAssertTrue(summary.contains("msg 4"))
        XCTAssertFalse(summary.contains("msg 1"))
    }
}
