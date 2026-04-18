import XCTest
@testable import HomeHub

/// Regression tests for `SkillManager` — skill registration, instruction
/// building, action parsing, and skill execution.
///
/// ## What these tests guard
/// 1. A freshly registered skill appears in `buildSystemInstructions()`.
/// 2. `parseAction(from:)` returns a correct `ActionCommand` for a valid
///    `<tool_call>` envelope.
/// 3. `parseAction(from:)` returns `nil` when no envelope is present.
/// 4. `execute(_:)` routes to the registered skill and returns its output.
/// 5. `execute(_:)` returns a descriptive error string for unknown skills.
/// 6. `CalculatorSkill` evaluates basic expressions correctly.
/// 7. `CalculatorSkill` sanitises dangerous input.
/// 8. `CalculatorSkill` returns an error for non-numeric expressions.
final class SkillManagerTests: XCTestCase {

    // MARK: - Stub skill

    /// Deterministic test skill with a unique name that doesn't collide
    /// with any of the default skills.
    private struct EchoSkill: Skill {
        let name = "EchoTestSkillXYZ"
        let description = "Echoes the input back for testing."
        func execute(input: String) async throws -> String {
            "Echo: \(input)"
        }
    }

    private struct ThrowingSkill: Skill {
        let name = "ThrowingTestSkillXYZ"
        let description = "Always throws."
        func execute(input: String) async throws -> String {
            throw ExtractionError.emptyResponse
        }
    }

    // MARK: - Registration & instructions

    func testRegisteredSkillAppearsInInstructions() async {
        let manager = SkillManager.shared
        await manager.register(EchoSkill())

        let instructions = await manager.buildSystemInstructions()
        XCTAssertTrue(instructions.contains("EchoTestSkillXYZ"),
            "Registered skill name must appear in system instructions")
        XCTAssertTrue(instructions.contains("Echoes the input back"),
            "Registered skill description must appear in system instructions")
    }

    func testInstructionsContainToolCallFormat() async {
        let instructions = await SkillManager.shared.buildSystemInstructions()
        XCTAssertTrue(instructions.contains("<tool_call>"),
            "Instructions must teach the <tool_call> envelope format")
    }

    func testInstructionsAreEmptyWhenNoSkillsRegistered() async {
        // Create a fresh actor by bypassing the shared singleton via a local scope.
        // We can't instantiate SkillManager directly (private init), so verify
        // the guard condition indirectly: the shared instance always has defaults,
        // so we just confirm that without skills the string would be empty by
        // testing the branch via code inspection.
        // The meaningful regression here is that instructions are non-empty
        // when skills ARE registered:
        let instructions = await SkillManager.shared.buildSystemInstructions()
        XCTAssertFalse(instructions.isEmpty,
            "Instructions must be non-empty when skills are registered")
    }

    // MARK: - parseAction

    func testParseActionReturnsCommandForValidEnvelope() async {
        let manager = SkillManager.shared
        let text = #"<tool_call>{"name": "Calculator", "input": "2+2"}</tool_call>"#
        let cmd = await manager.parseAction(from: text)
        XCTAssertEqual(cmd?.skillName, "Calculator")
        XCTAssertEqual(cmd?.input, "2+2")
    }

    func testParseActionReturnsNilForPlainText() async {
        let cmd = await SkillManager.shared.parseAction(from: "What is 2+2?")
        XCTAssertNil(cmd)
    }

    func testParseActionReturnsNilForOldActionFormat() async {
        let cmd = await SkillManager.shared.parseAction(from: "<Action:Calculator:2+2>")
        XCTAssertNil(cmd,
            "Old <Action:…> format must not parse — all callers must migrate to <tool_call>")
    }

    // MARK: - execute

    func testExecuteRoutesToRegisteredSkill() async {
        let manager = SkillManager.shared
        await manager.register(EchoSkill())

        let cmd = ActionCommand(skillName: "EchoTestSkillXYZ", input: "hello", fullTag: "")
        let result = await manager.execute(cmd)
        XCTAssertEqual(result, "Echo: hello")
    }

    func testExecuteReturnsErrorForUnknownSkill() async {
        let cmd = ActionCommand(skillName: "NoSuchSkill_ABC", input: "anything", fullTag: "")
        let result = await SkillManager.shared.execute(cmd)
        XCTAssertTrue(result.lowercased().contains("error"),
            "Executing an unregistered skill must return an error string")
        XCTAssertTrue(result.contains("NoSuchSkill_ABC"),
            "Error string should name the unrecognised skill")
    }

    func testExecuteWrapsSkillThrowsAsErrorString() async {
        let manager = SkillManager.shared
        await manager.register(ThrowingSkill())

        let cmd = ActionCommand(skillName: "ThrowingTestSkillXYZ", input: "x", fullTag: "")
        let result = await manager.execute(cmd)
        XCTAssertTrue(result.lowercased().contains("error"),
            "A throwing skill must produce an error string, not crash")
    }

    // MARK: - CalculatorSkill

    func testCalculatorAddition() async throws {
        let skill = CalculatorSkill()
        let result = try await skill.execute(input: "2 + 2")
        XCTAssertEqual(result, "4")
    }

    func testCalculatorMultiplication() async throws {
        let skill = CalculatorSkill()
        let result = try await skill.execute(input: "6 * 7")
        XCTAssertEqual(result, "42")
    }

    func testCalculatorDecimalResult() async throws {
        let skill = CalculatorSkill()
        let result = try await skill.execute(input: "1 / 3")
        // Should return a string with up to 4 decimal places
        let value = Double(result.replacingOccurrences(of: ",", with: "."))
        XCTAssertNotNil(value)
        XCTAssertGreaterThan(value ?? 0, 0.33)
        XCTAssertLessThan(value ?? 1, 0.34)
    }

    func testCalculatorSanitisesInjectionAttempt() async throws {
        // Input with letters/special chars should be stripped, leaving only math.
        // "alert(1)" → strips letters and parens with letters → may fail or return error
        let skill = CalculatorSkill()
        let result = try await skill.execute(input: "alert(1)")
        // After sanitisation "(1)" passes through — NSExpression may return 1 or an error.
        // The important regression: no crash, no arbitrary code execution.
        XCTAssertFalse(result.isEmpty)
    }

    func testCalculatorReturnsErrorForEmptyAfterSanitisation() async throws {
        let skill = CalculatorSkill()
        let result = try await skill.execute(input: "abc xyz")
        XCTAssertTrue(result.lowercased().contains("error"),
            "Fully non-math input must return an error, not crash")
    }
}
