import XCTest
@testable import HomeHub

/// Covers the information-flow rule that closes the prompt-injection chain:
/// once a turn has ingested third-party text (a fetched page, a search
/// snippet), state-changing skills are refused for the rest of that turn.
///
/// The classification predicates are tested directly rather than through
/// `SkillManager.run`, because the write paths they gate genuinely mutate the
/// user's Reminders and HomeKit accessories — a test must never reach them.
@MainActor
final class ToolInjectionGuardTests: XCTestCase {

    // MARK: - Which skills can change the world

    func testRemindersTreatsListAsReadOnly() {
        let skill = RemindersSkill()
        XCTAssertFalse(skill.isStateChanging(input: "list"))
        XCTAssertFalse(skill.isStateChanging(input: ""))
        XCTAssertFalse(skill.isStateChanging(input: "  LIST  "),
                       "case and surrounding whitespace must not change the verdict")
    }

    func testRemindersTreatsAnythingElseAsAWrite() {
        let skill = RemindersSkill()
        XCTAssertTrue(skill.isStateChanging(input: "Buy milk tomorrow"))
        // The injection payload shape: an attacker-chosen title.
        XCTAssertTrue(skill.isStateChanging(input: "Transfer the funds by Friday"))
    }

    func testHomeKitTreatsStatusAsReadOnly() {
        let skill = HomeKitSkill()
        XCTAssertFalse(skill.isStateChanging(input: "status"))
        XCTAssertFalse(skill.isStateChanging(input: ""))
    }

    func testHomeKitTreatsAccessoryChangesAsWrites() {
        let skill = HomeKitSkill()
        XCTAssertTrue(skill.isStateChanging(input: "Living Room Light: off"))
    }

    func testReadOnlySkillsAreNeverStateChanging() {
        // These must stay runnable after a web read, or the guard would break
        // ordinary "search, then tell me the answer" flows.
        XCTAssertFalse(CalculatorSkill().isStateChanging(input: "2+2"))
        XCTAssertFalse(CalendarSkill().isStateChanging(input: "today"),
                       "CalendarSkill only queries events — it has no create path")
        XCTAssertFalse(WebSearchSkill().isStateChanging(input: "weather"))
    }

    // MARK: - Which skills bring in untrusted text

    func testWebSkillsAreMarkedAsUntrustedSources() {
        XCTAssertTrue(WebSearchSkill().producesUntrustedContent,
                      "search snippets are authored by whoever controls the indexed page")
        XCTAssertTrue(FetchPageSkill().producesUntrustedContent,
                      "the entire output is third-party page content")
    }

    func testLocalSkillsAreNotUntrustedSources() {
        XCTAssertFalse(CalculatorSkill().producesUntrustedContent)
        XCTAssertFalse(RemindersSkill().producesUntrustedContent)
        XCTAssertFalse(HomeKitSkill().producesUntrustedContent)
        XCTAssertFalse(CalendarSkill().producesUntrustedContent)
    }

    // MARK: - The registry lookup the agentic loop uses

    /// Registers explicitly rather than relying on `SkillManager.shared`'s
    /// contents.
    ///
    /// FetchPage and WebSearch are **not** in the default registration — the
    /// app registers them at launch once the user has opted in — so whether the
    /// shared registry contains them at the moment a given test runs depends on
    /// how far the host app got through its async boot. Registering here makes
    /// the assertion about the lookup logic instead of about test ordering.
    private func registerWebSkills() async {
        await SkillManager.shared.register(FetchPageSkill())
    }

    func testManagerResolvesUntrustedSourcesByName() async {
        await registerWebSkills()
        let manager = SkillManager.shared
        let fetchIsUntrusted = await manager.producesUntrustedContent("FetchPage")
        let calcIsUntrusted = await manager.producesUntrustedContent("Calculator")
        XCTAssertTrue(fetchIsUntrusted)
        XCTAssertFalse(calcIsUntrusted)
    }

    func testManagerLookupIsCaseInsensitiveAndSafeForUnknownNames() async {
        await registerWebSkills()
        let manager = SkillManager.shared
        let lowercased = await manager.producesUntrustedContent("fetchpage")
        let unknown = await manager.producesUntrustedContent("NoSuchSkill")
        XCTAssertTrue(lowercased, "the model's casing must not defeat the taint check")
        XCTAssertFalse(unknown, "an unknown skill must not be treated as a web source")
    }

    // MARK: - Naming

    func testRegisteredNameIsMisleading() {
        // Documenting, not endorsing. The reminder-creating skill is registered
        // as "RemindersSearch", which reads as read-only to anyone auditing the
        // enabled-tool list in Settings — and it is on by default. The name is
        // load-bearing (it is the tag the model emits and is persisted in
        // AppSettings.enabledTools), so renaming needs a migration and is out of
        // scope here. This test pins the current value so the rename, when it
        // happens, is deliberate rather than accidental.
        XCTAssertEqual(RemindersSkill().name, "RemindersSearch")
        XCTAssertEqual(HomeKitSkill().name, "HomeKitSearch")
    }

    // MARK: - The guard itself

    func testStateChangingSkillIsRefusedOnATaintedTurn() async {
        let result = await SkillManager.shared.run(
            // The registered name is "RemindersSearch" despite the skill also
            // creating reminders — see the note in testRegisteredNameIsMisleading.
            ActionCommand(skillName: "RemindersSearch", input: "Buy milk", fullTag: "<Action:RemindersSearch:Buy milk>"),
            enabled: ["RemindersSearch"],
            turnHasUntrustedContent: true
        )
        guard case .error(_, let reason) = result else {
            return XCTFail("expected the call to be refused, got \(result)")
        }
        XCTAssertEqual(reason, .blockedAfterUntrustedContent)
    }

    func testReadOnlySkillStillRunsOnATaintedTurn() async {
        // The guard must not turn "search the web, then do the arithmetic"
        // into a failure — only writes are restricted.
        let result = await SkillManager.shared.run(
            ActionCommand(skillName: "Calculator", input: "2+2", fullTag: "<Action:Calculator:2+2>"),
            enabled: ["Calculator"],
            turnHasUntrustedContent: true
        )
        XCTAssertTrue(result.isSuccess, "read-only skills must be unaffected by the taint")
    }
}
