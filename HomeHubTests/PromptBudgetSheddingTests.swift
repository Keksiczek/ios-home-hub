import XCTest
@testable import HomeHub

/// Covers the two structural changes to prompt assembly:
///
///  * `fitVolatileLayers` — priority-ordered shedding, which replaced the
///    binary `isWeakInstructionFollower` on/off gating of context layers.
///  * `ToolObservationEnvelope` — the marker that lets a tool result be
///    promoted to `RuntimeMessage.Role.tool` without migrating the persisted
///    `Message.Role` enum.
@MainActor
final class PromptBudgetSheddingTests: XCTestCase {

    // MARK: - Helpers

    private func layer(
        _ priority: PromptAssemblyService.ContextLayer.Priority,
        _ name: String,
        tokens: Int
    ) -> PromptAssemblyService.ContextLayer {
        // The heuristic estimator is roughly chars/4, so 4 chars ≈ 1 token.
        // Exact ratios don't matter here: every assertion below compares
        // *which* layers survived, never an absolute token count.
        //
        // The body is seeded with the layer name so two same-sized layers
        // produce distinguishable text. Without that, `result.contains(...)`
        // matches any equally-sized layer and the ordering assertions pass or
        // fail for the wrong reason.
        PromptAssemblyService.ContextLayer(
            priority: priority,
            name: name,
            text: name + " " + String(repeating: "x ", count: tokens * 2)
        )
    }

    private var budgeter: PromptTokenBudgeter { PromptTokenBudgeter(profile: .default) }

    private func fit(
        _ layers: [PromptAssemblyService.ContextLayer],
        stableTokens: Int = 0,
        historyTokens: Int = 0,
        userInputTokens: Int = 0
    ) -> String {
        PromptAssemblyService.fitVolatileLayers(
            layers,
            stableTokens: stableTokens,
            historyTokens: historyTokens,
            userInputTokens: userInputTokens,
            profile: .default,
            budgeter: budgeter
        )
    }

    // MARK: - Shedding order

    func testKeepsEverythingWhenItFitsInBudget() {
        let layers = [
            layer(.essential, "rail", tokens: 10),
            layer(.summary, "summary", tokens: 10),
            layer(.facts, "facts", tokens: 10)
        ]
        let result = fit(layers)
        for l in layers {
            XCTAssertTrue(result.contains(l.text), "\(l.name) should survive an unconstrained budget")
        }
    }

    func testShedsLowestPriorityFirst() {
        // Force pressure by committing nearly the whole window to the stable
        // half, leaving room for only a fraction of the volatile layers.
        let window = DeviceMemoryProvider.shared.profile.contextWindowTokens
        let reserve = ModelCapabilityProfile.default.generationReserveTokens
        let excerpts = layer(.fileExcerpts, "excerpts", tokens: 400)
        let facts = layer(.facts, "facts", tokens: 100)
        let rail = layer(.essential, "rail", tokens: 20)

        let result = fit(
            [excerpts, facts, rail],
            stableTokens: window - reserve - 200
        )

        XCTAssertFalse(result.contains(excerpts.text), "file excerpts are lowest priority and must go first")
        XCTAssertTrue(result.contains(rail.text), "the essential rail must never be shed")
    }

    func testNeverShedsEssentialEvenWhenNothingElseRemains() {
        let window = DeviceMemoryProvider.shared.profile.contextWindowTokens
        let rail = layer(.essential, "rail", tokens: 300)

        // Commit the entire window so no budget is left at all.
        let result = fit([rail], stableTokens: window)

        XCTAssertTrue(
            result.contains(rail.text),
            "an over-budget prompt is recoverable; a prompt with no date rail answers time questions wrongly"
        )
    }

    func testShedsInStrictPriorityOrderNotInputOrder() {
        // Deliberately supply the layers highest-priority-first so a naive
        // implementation that trims from the end would pick the wrong ones.
        let window = DeviceMemoryProvider.shared.profile.contextWindowTokens
        let reserve = ModelCapabilityProfile.default.generationReserveTokens
        let summary = layer(.summary, "summary", tokens: 150)
        let facts = layer(.facts, "facts", tokens: 150)
        let episodes = layer(.episodes, "episodes", tokens: 150)

        let result = fit(
            [summary, facts, episodes],
            stableTokens: window - reserve - 320
        )

        XCTAssertTrue(result.contains(summary.text), "summary outranks facts and episodes")
        XCTAssertFalse(result.contains(episodes.text), "episodes rank below facts and must go first")
    }

    func testEmptyLayerListProducesEmptyString() {
        XCTAssertEqual(fit([]), "")
    }

    // MARK: - Tool observation envelope

    func testEnvelopeRoundTrips() {
        let wrapped = ToolObservationEnvelope.wrap("temperature: 21C")
        XCTAssertTrue(ToolObservationEnvelope.matches(wrapped))
    }

    func testEnvelopeToleratesSurroundingWhitespace() {
        let wrapped = "\n  " + ToolObservationEnvelope.wrap("result") + "  \n"
        XCTAssertTrue(ToolObservationEnvelope.matches(wrapped))
    }

    func testEnvelopeDoesNotMatchUserMentioningTheTag() {
        // A user asking about the app's own tool format must not have their
        // turn silently reclassified as a machine-generated tool result.
        XCTAssertFalse(ToolObservationEnvelope.matches(
            "why does the model emit <Observation> tags in its replies?"
        ))
        XCTAssertFalse(ToolObservationEnvelope.matches("<Observation> unterminated"))
        XCTAssertFalse(ToolObservationEnvelope.matches("trailing only </Observation>"))
    }
}
