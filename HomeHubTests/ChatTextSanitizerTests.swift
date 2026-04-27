import XCTest
@testable import HomeHub

/// Sanitizer guards three categories of issues:
///   1. control-token leaks (`<|im_start|>`, `<|eot_id|>`, `[INST]`, …)
///   2. UTF-8 garbage (U+FFFD, NUL, C0 control chars)
///   3. cosmetic artifacts (echoed role headers, triple newlines, trailing spaces)
final class ChatTextSanitizerTests: XCTestCase {

    // MARK: - Control tokens

    func testStripsLlama3HeaderTokens() {
        let raw = "<|begin_of_text|><|start_header_id|>assistant<|end_header_id|>\n\nHello.<|eot_id|>"
        XCTAssertEqual(ChatTextSanitizer.strip(raw), "Hello.")
    }

    func testStripsChatMLTokens() {
        let raw = "<|im_start|>assistant\nAhoj!<|im_end|>"
        // First line "assistant" gets dropped as a stray role header,
        // leaving the body. Both control tokens disappear too.
        XCTAssertEqual(ChatTextSanitizer.strip(raw), "Ahoj!")
    }

    func testStripsGemmaTokens() {
        let raw = "<start_of_turn>model\nDobrý den.<end_of_turn>"
        XCTAssertEqual(ChatTextSanitizer.strip(raw), "Dobrý den.")
    }

    func testStripsMistralInstructTokens() {
        let raw = "[INST] hi [/INST] Howdy, partner."
        XCTAssertEqual(ChatTextSanitizer.strip(raw), "hi  Howdy, partner.")
    }

    func testStripsPhiTokens() {
        let raw = "<|user|>q<|end|><|assistant|>Yes."
        XCTAssertEqual(ChatTextSanitizer.strip(raw), "qYes.")
    }

    // MARK: - UTF-8 garbage

    func testStripsReplacementCharacter() {
        let raw = "Czech \u{FFFD}\u{FFFD}\u{FFFD} chars."
        XCTAssertEqual(ChatTextSanitizer.strip(raw), "Czech  chars.")
    }

    func testStripsC0ControlCharsButKeepsTabsAndNewlines() {
        let raw = "Hello\u{0007}\u{0008}\tWorld\nNext"
        XCTAssertEqual(ChatTextSanitizer.strip(raw), "Hello\tWorld\nNext")
    }

    func testStripsNullBytes() {
        let raw = "Pre\u{0000}fix"
        XCTAssertEqual(ChatTextSanitizer.strip(raw), "Prefix")
    }

    // MARK: - Cosmetic

    func testCollapsesTripleNewlines() {
        let raw = "First\n\n\n\nSecond"
        XCTAssertEqual(ChatTextSanitizer.strip(raw), "First\n\nSecond")
    }

    func testTrimsTrailingWhitespacePerLine() {
        let raw = "Line A   \nLine B\t\nLine C"
        XCTAssertEqual(ChatTextSanitizer.strip(raw), "Line A\nLine B\nLine C")
    }

    func testPreservesMarkdown() {
        let raw = "**bold** and `code` and a list:\n- item 1\n- item 2"
        XCTAssertEqual(ChatTextSanitizer.strip(raw), raw)
    }

    func testPreservesToolCallEnvelope() {
        let raw = "<tool_call>{\"name\":\"X\",\"input\":\"y\"}</tool_call>"
        XCTAssertEqual(ChatTextSanitizer.strip(raw), raw,
            "Tool-call envelopes are structural and must round-trip untouched.")
    }

    // MARK: - UTF-8 prefix helper (LlamaContextHandle)

    func testDrainValidUTF8PrefixSplitsMidCodepoint() {
        // "č" is 0xC4 0x8D in UTF-8. Slicing after the lead byte should
        // hold the partial sequence in `leftover`, not produce a U+FFFD.
        let bytes: [UInt8] = [0x68, 0x69, 0xC4]   // "hi" + lead-of-č
        let (decoded, leftover) = LlamaContextHandle.drainValidUTF8Prefix(from: bytes)
        XCTAssertEqual(decoded, "hi")
        XCTAssertEqual(leftover, [0xC4])
    }

    func testDrainValidUTF8PrefixCompletesCodepoint() {
        // Full encoding of "č" — should decode fully, leaving nothing.
        let bytes: [UInt8] = [0xC4, 0x8D]
        let (decoded, leftover) = LlamaContextHandle.drainValidUTF8Prefix(from: bytes)
        XCTAssertEqual(decoded, "č")
        XCTAssertEqual(leftover, [])
    }

    func testDrainValidUTF8PrefixHandlesEmoji() {
        // 4-byte sequence (😀 = 0xF0 0x9F 0x98 0x80). Cut after 2 bytes —
        // leftover is the partial 4-byte head waiting for completion.
        let bytes: [UInt8] = [0xF0, 0x9F]
        let (decoded, leftover) = LlamaContextHandle.drainValidUTF8Prefix(from: bytes)
        XCTAssertEqual(decoded, "")
        XCTAssertEqual(leftover, [0xF0, 0x9F])
    }
}
