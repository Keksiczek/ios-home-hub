import XCTest
@testable import HomeHub

/// Pins the rail's stable / volatile partition.
///
/// The MLX KV-cache prefix is reused across turns when `stableSystemPrompt`
/// is byte-identical to the previous turn's value. The big win we depend
/// on is that **only `dateTimeBlock` lives in volatile** — everything
/// else (language, location, tool policy, style) is stable and survives
/// across turns until the user toggles a Settings switch.
///
/// If a future refactor accidentally moves a stable block back into
/// volatile, these tests fail.
final class PromptBuilderRailSplitTests: XCTestCase {

    // MARK: - Helpers

    private func makeContext(
        date: Date = Date(timeIntervalSince1970: 1_777_622_400), // 2026-04-30 12:00 UTC
        language: AppLanguage = .cs,
        location: String = "Nymburk, CZ",
        tools: Set<String> = ["Calculator", "WebSearch"],
        weak: Bool = true
    ) -> PromptBuilder.Context {
        var s = AppSettings.default
        s.language = language
        s.locationHint = location
        s.answerLength = .balanced
        return PromptBuilder.Context(
            settings: s,
            now: date,
            locale: Locale(identifier: "cs_CZ"),
            timeZone: TimeZone(identifier: "Europe/Prague")!,
            availableTools: tools,
            isWeakInstructionFollower: weak
        )
    }

    // MARK: - Stable rail content

    func testStableRailContainsLanguageToolPolicyStyleLocation() {
        let stable = PromptBuilder.contextRailStable(makeContext())
        XCTAssertTrue(stable.contains("Language policy:"),
                      "Stable rail must carry language policy:\n\(stable)")
        XCTAssertTrue(stable.contains("Tool policy:"),
                      "Stable rail must carry tool policy:\n\(stable)")
        XCTAssertTrue(stable.contains("Answer length"),
                      "Stable rail must carry answer-length style block:\n\(stable)")
        XCTAssertTrue(stable.contains("Nymburk, CZ"),
                      "Stable rail must carry location hint:\n\(stable)")
    }

    func testStableRailExcludesDate() {
        let stable = PromptBuilder.contextRailStable(makeContext())
        XCTAssertFalse(stable.contains("Current date:"),
                       "Stable rail must NOT include the date — that's volatile:\n\(stable)")
        XCTAssertFalse(stable.contains("Local time:"),
                       "Stable rail must NOT include local time:\n\(stable)")
    }

    func testStableRailIsByteIdenticalAcrossSameDay() {
        // Two different times on the same UTC instant — language /
        // location / tools unchanged. The stable rail must produce a
        // byte-identical string so the KV-cache prefix is reusable.
        let early = makeContext(date: Date(timeIntervalSince1970: 1_777_622_400))      // noon
        let later = makeContext(date: Date(timeIntervalSince1970: 1_777_622_400 + 7200)) // +2h
        XCTAssertEqual(
            PromptBuilder.contextRailStable(early),
            PromptBuilder.contextRailStable(later),
            "Stable rail must NOT depend on the wall clock — would defeat KV-cache reuse"
        )
    }

    // MARK: - Volatile rail content

    func testVolatileRailContainsOnlyDateTimeAndGuards() {
        let volatileBlock = PromptBuilder.contextRailVolatile(makeContext())
        XCTAssertTrue(volatileBlock.contains("Current date:"),
                      "Volatile rail must carry date:\n\(volatileBlock)")
        XCTAssertTrue(volatileBlock.contains("Local time:"),
                      "Volatile rail must carry local time:\n\(volatileBlock)")
        // Negative: heavy stable content must NOT leak into volatile.
        XCTAssertFalse(volatileBlock.contains("Language policy:"),
                       "Volatile rail must NOT carry language policy:\n\(volatileBlock)")
        XCTAssertFalse(volatileBlock.contains("Tool policy:"),
                       "Volatile rail must NOT carry tool policy:\n\(volatileBlock)")
        XCTAssertFalse(volatileBlock.contains("Answer length"),
                       "Volatile rail must NOT carry style block:\n\(volatileBlock)")
    }

    // MARK: - Anti-parrot guard for weak models

    func testVolatileRailIncludesAntiParrotGuardForWeak() {
        let block = PromptBuilder.contextRailVolatile(makeContext(weak: true))
        XCTAssertTrue(block.contains("NEPOZDRAVUJ"),
                      "Weak rail must carry anti-parrot guard:\n\(block)")
        XCTAssertTrue(block.contains("Dnes: "),
                      "Weak Czech rail uses plain-fact date hint, not verbatim quote:\n\(block)")
        XCTAssertFalse(block.contains("použij přesně tuto formulaci"),
                       "Weak rail must NOT carry verbatim quote instruction:\n\(block)")
    }

    func testVolatileRailUsesVerbatimDateHintForStrong() {
        let block = PromptBuilder.contextRailVolatile(makeContext(weak: false))
        XCTAssertFalse(block.contains("NEPOZDRAVUJ"),
                       "Strong rail must NOT carry the anti-parrot guard:\n\(block)")
        XCTAssertTrue(block.contains("použij přesně tuto formulaci"),
                      "Strong Czech rail keeps the verbatim quote instruction:\n\(block)")
    }
}
