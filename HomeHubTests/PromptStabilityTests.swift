import XCTest
@testable import HomeHub

/// Pinning tests for the stable / volatile system-prompt split.
///
/// The split is the foundation for future KV-cache prefix reuse —
/// downstream MLX integration can pin the stable bytes once and let
/// volatile rebuild on every turn. If a future refactor silently
/// moves a block between sides, the cache would either miss every
/// turn (block moved out of stable) or invalidate every turn (block
/// moved into stable). Both are silent perf regressions; these tests
/// fail loudly instead.
@MainActor
final class PromptStabilityTests: XCTestCase {

    private let service = PromptAssemblyService()

    private func makePackage(
        facts: [MemoryFact] = [],
        episodes: [MemoryEpisode] = [],
        recall: [String] = [],
        summary: String? = nil,
        userInput: String = "Hello"
    ) -> PromptContextPackage {
        PromptContextPackage(
            assistant: AssistantProfile.defaultAssistant,
            user: UserProfile(
                id: UUID(),
                displayName: "Alex",
                pronouns: "they/them",
                occupation: "Product designer",
                locale: "en_US",
                interests: ["typography"],
                workingContext: "Building Home Hub",
                preferredResponseStyle: .balanced,
                createdAt: .now,
                updatedAt: .now
            ),
            facts: facts,
            episodes: episodes,
            recentMessages: [],
            userInput: userInput,
            settings: .default,
            conversationSummary: summary,
            conversationRecall: recall
        )
    }

    // MARK: - Stable side invariants

    /// The persona block must live on the stable side — that's the
    /// largest single contributor to the prompt and the one that
    /// changes least often. Putting it on volatile would mean we
    /// never get a cache hit even on a same-second follow-up turn.
    func testPersonaIsInStablePrompt() {
        let prompt = service.build(from: makePackage())
        XCTAssertTrue(
            prompt.stableSystemPrompt.contains(AssistantProfile.defaultAssistant.systemPromptBase),
            "Persona must be in the stable half so it can be cache-pinned"
        )
        XCTAssertFalse(
            prompt.volatileSystemPrompt.contains(AssistantProfile.defaultAssistant.systemPromptBase),
            "Persona must NOT also appear in volatile (double-render)"
        )
    }

    /// The user-profile block (name / pronouns / work / interests)
    /// changes only when the user edits onboarding. Stable.
    func testUserProfileIsInStablePrompt() {
        let prompt = service.build(from: makePackage())
        XCTAssertTrue(prompt.stableSystemPrompt.contains("Name: Alex"))
        XCTAssertFalse(prompt.volatileSystemPrompt.contains("Name: Alex"))
    }

    // MARK: - Volatile side invariants

    /// The conversation summary is regenerated whenever the auto-
    /// summarizer fires. Must be volatile so a fresh summary
    /// invalidates only its own slice, not the persona prefix.
    func testSummaryIsInVolatilePrompt() {
        let prompt = service.build(from: makePackage(summary: "We talked about Swift testing"))
        XCTAssertTrue(prompt.volatileSystemPrompt.contains("We talked about Swift testing"))
        XCTAssertFalse(prompt.stableSystemPrompt.contains("We talked about Swift testing"))
    }

    /// Recall snippets are computed per-turn via semantic similarity
    /// to the user input. Pure volatile.
    func testRecallIsInVolatilePrompt() {
        let prompt = service.build(from: makePackage(recall: ["[Uživatel] earlier turn"]))
        XCTAssertTrue(prompt.volatileSystemPrompt.contains("earlier turn"))
        XCTAssertFalse(prompt.stableSystemPrompt.contains("earlier turn"))
    }

    // MARK: - RuntimePrompt contract

    /// The legacy `systemPrompt` getter must concatenate stable +
    /// volatile so existing runtime call sites keep working without
    /// modification. The order matters — stable first, volatile last,
    /// so the cache-pinnable bytes are at the front of the string.
    func testSystemPromptComposition() {
        let prompt = RuntimePrompt(
            stableSystemPrompt: "STABLE",
            volatileSystemPrompt: "VOLATILE",
            messages: []
        )
        XCTAssertEqual(prompt.systemPrompt, "STABLE\n\nVOLATILE")
    }

    /// Legacy setter (callers using `RuntimePrompt(systemPrompt:messages:)`)
    /// must put the whole string into stable — there's no signal to
    /// split a pre-joined string, and treating the assignment as
    /// "all stable" is the safest fallback (worst case: no cache hit
    /// on volatile, but correctness is preserved).
    func testLegacyInitTreatsAllAsStable() {
        let prompt = RuntimePrompt(systemPrompt: "all in one", messages: [])
        XCTAssertEqual(prompt.stableSystemPrompt, "all in one")
        XCTAssertEqual(prompt.volatileSystemPrompt, "")
        XCTAssertEqual(prompt.systemPrompt, "all in one")
    }

    /// Empty volatile must not introduce a stray "\n\n" suffix on
    /// the composed system prompt — would otherwise drift the byte
    /// count and could confuse strict tokenizers that hash on the
    /// whole string.
    func testEmptyVolatileProducesCleanComposition() {
        let prompt = RuntimePrompt(
            stableSystemPrompt: "STABLE",
            volatileSystemPrompt: "",
            messages: []
        )
        XCTAssertEqual(prompt.systemPrompt, "STABLE")
    }

    // MARK: - Budget report sections

    /// The budget report must surface `system.stable` and
    /// `system.volatile` as separate sections so diagnostics can
    /// compute the cacheable fraction without re-running the
    /// assembler. Replaces the historic single `system` section.
    func testBudgetReportEmitsStableAndVolatileSections() {
        let reporter = PromptBudgetReporter()
        let svc = PromptAssemblyService(reporter: reporter)
        _ = svc.build(from: makePackage(summary: "older context"))

        let report = reporter.lastReport
        XCTAssertNotNil(report)
        let names = Set(report?.sections.map(\.name) ?? [])
        XCTAssertTrue(names.contains("system.stable"),
                      "Missing system.stable section — diagnostics can't compute cacheable fraction")
        XCTAssertTrue(names.contains("system.volatile"))
    }

    /// Sum of the per-section tokens must still equal
    /// `totalPromptTokens`. Locks down the additive contract: a
    /// careless refactor that double-counted summary would inflate
    /// the total and trigger spurious budget alerts.
    func testBudgetReportSectionsSumToTotal() {
        let reporter = PromptBudgetReporter()
        let svc = PromptAssemblyService(reporter: reporter)
        _ = svc.build(from: makePackage(
            facts: [],
            recall: ["[Uživatel] foo", "[Asistent] bar"],
            summary: "older condensed context"
        ))

        guard let report = reporter.lastReport else {
            return XCTFail("Reporter didn't receive a report")
        }
        let sum = report.sections.reduce(0) { $0 + $1.tokens }
        XCTAssertEqual(sum, report.totalPromptTokens,
                       "Section tokens must sum to totalPromptTokens — additive invariant broken")
    }
}
