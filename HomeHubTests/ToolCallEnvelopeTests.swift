import XCTest
@testable import HomeHub

/// Tests for `ToolCallEnvelope.parse(from:)` and `toActionCommand()`.
///
/// ## What these tests guard
/// 1. Valid compact envelope parses to correct name + input.
/// 2. Whitespace / newlines around JSON are tolerated.
/// 3. Inputs containing `:` (e.g. URLs) parse without corruption.
/// 4. Inputs containing `>` (comparison operators) parse correctly.
/// 5. Envelope embedded in prose still parses.
/// 6. Missing `name` field → nil.
/// 7. Missing `input` field → empty input (no-argument skills are valid).
/// 8. Invalid JSON between the tags → nil.
/// 9. No tags present → nil.
/// 10. Empty string → nil.
/// 11. `toActionCommand()` propagates name, input, and fullTag correctly.
/// 12. `SkillManager.parseAction` delegates to `ToolCallEnvelope.parse`.
final class ToolCallEnvelopeTests: XCTestCase {

    // MARK: - Happy paths

    func testCompactEnvelopeParsesCorrectly() {
        let text = #"<tool_call>{"name": "Calculator", "input": "2+2"}</tool_call>"#
        let env = ToolCallEnvelope.parse(from: text)
        XCTAssertEqual(env?.name, "Calculator")
        XCTAssertEqual(env?.input, "2+2")
    }

    func testWhitespaceAroundJSONIsTolerated() {
        let text = "<tool_call>\n  {\"name\": \"Calculator\", \"input\": \"3*3\"}\n</tool_call>"
        let env = ToolCallEnvelope.parse(from: text)
        XCTAssertEqual(env?.name, "Calculator")
        XCTAssertEqual(env?.input, "3*3")
    }

    func testInputContainingColons() {
        let json = #"{"name": "WebSearch", "input": "https://example.com/path?a=1&b=2"}"#
        let text = "<tool_call>\(json)</tool_call>"
        let env = ToolCallEnvelope.parse(from: text)
        XCTAssertEqual(env?.name, "WebSearch")
        XCTAssertEqual(env?.input, "https://example.com/path?a=1&b=2",
            "Colons inside the JSON input must not corrupt parsing")
    }

    func testInputContainingGreaterThan() {
        // A Calculator input like "10 > 5" would have broken the old <Action:…> regex.
        // In JSON it's escaped as \u003e or kept as > — JSONDecoder handles both.
        let json = #"{"name": "Calculator", "input": "10 > 5 ? 1 : 0"}"#
        let text = "<tool_call>\(json)</tool_call>"
        let env = ToolCallEnvelope.parse(from: text)
        XCTAssertEqual(env?.name, "Calculator")
        XCTAssertNotNil(env?.input)
    }

    func testEnvelopeEmbeddedInProse() {
        let text = """
        Sure, let me calculate that for you.
        <tool_call>{"name": "Calculator", "input": "42 * 7"}</tool_call>
        """
        let env = ToolCallEnvelope.parse(from: text)
        XCTAssertEqual(env?.name, "Calculator")
        XCTAssertEqual(env?.input, "42 * 7")
    }

    func testOnlyFirstEnvelopeParsed() {
        // Two tool_call blocks — only the first is returned.
        let text = """
        <tool_call>{"name": "Calculator", "input": "1+1"}</tool_call>
        <tool_call>{"name": "WebSearch", "input": "swift"}</tool_call>
        """
        let env = ToolCallEnvelope.parse(from: text)
        XCTAssertEqual(env?.name, "Calculator")
    }

    func testHomeKitStyleJSONInput() {
        // HomeKit inputs are JSON strings, which contain colons and braces.
        // The input value itself is a JSON string (not nested JSON).
        let inputStr = #"{"accessoryName": "Light", "characteristic": "powerState", "value": true}"#
        // Build the envelope by encoding the input as a JSON string value:
        let data = try? JSONSerialization.data(withJSONObject: ["name": "HomeKitSearch", "input": inputStr])
        let jsonStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let text = "<tool_call>\(jsonStr)</tool_call>"
        let env = ToolCallEnvelope.parse(from: text)
        XCTAssertEqual(env?.name, "HomeKitSearch")
        XCTAssertEqual(env?.input, inputStr)
    }

    // MARK: - Failure paths

    func testMissingNameFieldReturnsNil() {
        let text = #"<tool_call>{"input": "2+2"}</tool_call>"#
        XCTAssertNil(ToolCallEnvelope.parse(from: text))
    }

    /// A missing `input` field parses to an EMPTY input, not to nil.
    ///
    /// This was `XCTAssertNil` until the universal tool-call parser
    /// landed, and the relaxation is deliberate: `DeviceInfoSkill.execute`
    /// ignores its input entirely, so `{"name": "DeviceInfo"}` is a
    /// well-formed call. Requiring `input` would reject every no-argument
    /// skill.
    ///
    /// Safe downstream: `CalculatorSkill` answers an empty expression with
    /// "Error: No valid math expression provided.", and
    /// `isStateChanging("")` is false for every write-capable skill, so an
    /// empty input can never dispatch a state change.
    func testMissingInputFieldParsesToEmptyInput() {
        let text = #"<tool_call>{"name": "Calculator"}</tool_call>"#
        let envelope = ToolCallEnvelope.parse(from: text)
        XCTAssertEqual(envelope?.name, "Calculator")
        XCTAssertEqual(envelope?.input, "")
    }

    func testInvalidJSONReturnsNil() {
        let text = "<tool_call>not json at all</tool_call>"
        XCTAssertNil(ToolCallEnvelope.parse(from: text))
    }

    func testNoTagsReturnsNil() {
        XCTAssertNil(ToolCallEnvelope.parse(from: "Calculate 2+2 for me"))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(ToolCallEnvelope.parse(from: ""))
    }

    /// A dropped closing tag around OTHERWISE COMPLETE JSON is salvaged.
    ///
    /// Also a deliberate relaxation. `looksLikeToolCallAttempt` matches on
    /// the `tool_call` substring, then `extractFirstJSONObject` recovers a
    /// brace-balanced object. Small models drop closing tags routinely —
    /// this codebase is built around that fact — and the payload here is
    /// complete, so refusing it would discard a call the model fully
    /// emitted.
    ///
    /// The safety argument rests on *balance*: salvage requires balanced
    /// braces, so a generation truncated mid-JSON cannot be recovered.
    /// `testUnbalancedJSONIsNotSalvaged` pins that boundary — the two
    /// tests are only meaningful as a pair.
    func testOpenTagWithoutCloseTagIsSalvaged() {
        let text = #"<tool_call>{"name": "Calculator", "input": "2+2"}"#
        let envelope = ToolCallEnvelope.parse(from: text)
        XCTAssertEqual(envelope?.name, "Calculator")
        XCTAssertEqual(envelope?.input, "2+2")
    }

    /// The boundary the salvage path must NOT cross: unbalanced braces
    /// mean the model was cut off mid-emission, and acting on a partial
    /// tool call is exactly the failure the balance requirement prevents.
    func testUnbalancedJSONIsNotSalvaged() {
        let text = #"<tool_call>{"name": "Calculator", "input": "2+2""#
        XCTAssertNil(ToolCallEnvelope.parse(from: text))
    }

    func testEmptyTagContentReturnsNil() {
        XCTAssertNil(ToolCallEnvelope.parse(from: "<tool_call></tool_call>"))
    }

    // MARK: - toActionCommand

    func testToActionCommandPropagatesName() {
        let env = ToolCallEnvelope(name: "Calculator", input: "1+1")
        XCTAssertEqual(env.toActionCommand().skillName, "Calculator")
    }

    func testToActionCommandPropagatesInput() {
        let env = ToolCallEnvelope(name: "Calculator", input: "1+1")
        XCTAssertEqual(env.toActionCommand().input, "1+1")
    }

    func testToActionCommandFullTagContainsBothTags() {
        let env = ToolCallEnvelope(name: "Calculator", input: "1+1")
        let tag = env.toActionCommand().fullTag
        XCTAssertTrue(tag.contains("<tool_call>"))
        XCTAssertTrue(tag.contains("</tool_call>"))
    }

    func testToActionCommandEscapesQuotesInInput() {
        let env = ToolCallEnvelope(name: "X", input: #"He said "hello""#)
        let tag = env.toActionCommand().fullTag
        XCTAssertFalse(tag.contains("\"hello\""),
            "Unescaped double-quotes in input should not appear in the fullTag JSON")
    }

    // MARK: - SkillManager integration

    func testSkillManagerParseActionUsesEnvelope() async {
        let manager = await SkillManager.shared
        let text = #"<tool_call>{"name": "Calculator", "input": "7*6"}</tool_call>"#
        let cmd = await manager.parseAction(from: text)
        XCTAssertEqual(cmd?.skillName, "Calculator")
        XCTAssertEqual(cmd?.input, "7*6")
    }

    func testSkillManagerParseActionReturnsNilForOldFormat() async {
        let manager = await SkillManager.shared
        let text = "<Action:Calculator:2+2>"
        let cmd = await manager.parseAction(from: text)
        XCTAssertNil(cmd,
            "Old <Action:…> format must no longer parse — model must use <tool_call>")
    }

    func testSkillManagerBuildInstructionsContainsNewFormat() async {
        let instructions = await SkillManager.shared.buildSystemInstructions()
        XCTAssertTrue(instructions.contains("<tool_call>"),
            "System instructions must teach the <tool_call> format")
        XCTAssertFalse(instructions.contains("<Action:"),
            "Old <Action:…> format must not appear in instructions")
    }
}
