import XCTest
@testable import HomeHub

/// Regression tests for `ConversationService.parseImagePromptCommand(_:)`.
///
/// The parser sits between the user's chat input and the early-return into
/// `performImageGeneration`. A misparse here either:
///   - silently routes a real `/image cat` prompt through the LLM path
///     (user sees text describing a cat instead of an image), or
///   - hijacks "/imagery" / unrelated text into the image runtime (wasted
///     diffusion cycles + bewildered user).
///
/// These tests pin every edge case the L2 review surfaced so a future
/// refactor (e.g. adding `/draw`, switching to regex, normalising the
/// body's case) can't reintroduce a regression silently.
final class ImagePromptCommandTests: XCTestCase {

    // MARK: - Happy paths

    func testImagePrefixExtractsBody() {
        XCTAssertEqual(ConversationService.parseImagePromptCommand("/image cat"), "cat")
    }

    func testImgPrefixExtractsBody() {
        XCTAssertEqual(ConversationService.parseImagePromptCommand("/img a moonlit fox"), "a moonlit fox")
    }

    func testUppercasePrefixNormalisedButBodyPreserved() {
        // The prefix match is case-insensitive (`.lowercased()` on the
        // whole input for the prefix check), but `dropFirst` operates
        // on the *original* trimmed string, so the body's case is
        // preserved verbatim. This matters: SD models care about case
        // in some prompts ("Mona Lisa" vs. "mona lisa" → different
        // attention weights via CLIP's BPE tokens).
        XCTAssertEqual(ConversationService.parseImagePromptCommand("/IMAGE Mona Lisa"), "Mona Lisa")
        XCTAssertEqual(ConversationService.parseImagePromptCommand("/Img Eiffel TOWER"), "Eiffel TOWER")
    }

    func testMixedCaseImgPrefix() {
        XCTAssertEqual(ConversationService.parseImagePromptCommand("/Image cat"), "cat")
    }

    // MARK: - Whitespace tolerance

    func testLeadingWhitespaceTrimmed() {
        XCTAssertEqual(ConversationService.parseImagePromptCommand("   /image cat"), "cat")
    }

    func testTrailingWhitespaceTrimmed() {
        XCTAssertEqual(ConversationService.parseImagePromptCommand("/image cat   "), "cat")
    }

    func testExtraInternalWhitespaceTrimmedFromBody() {
        // `/image   trim me  ` → "trim me" (only outer whitespace is
        // collapsed; runs *inside* the body are intentionally
        // preserved — users may use them deliberately, and the
        // CLIP tokenizer collapses runs of whitespace itself).
        XCTAssertEqual(ConversationService.parseImagePromptCommand("/image    trim me  "), "trim me")
    }

    // MARK: - Negative cases (must fall through to LLM path)

    func testEmptyBodyReturnsNil() {
        XCTAssertNil(ConversationService.parseImagePromptCommand("/image"))
        XCTAssertNil(ConversationService.parseImagePromptCommand("/image "))
        XCTAssertNil(ConversationService.parseImagePromptCommand("/image    "))
    }

    func testMissingSlashFallsThrough() {
        XCTAssertNil(ConversationService.parseImagePromptCommand("image cat"))
        XCTAssertNil(ConversationService.parseImagePromptCommand("img cat"))
    }

    func testLookalikePrefixDoesNotMatch() {
        // Trailing space in the prefix tokens (`"/image "`, `"/img "`)
        // is what stops `/imagery` from hijacking the image runtime.
        // If a future change collapses the space the parser will
        // silently regress — these assertions are the canary.
        XCTAssertNil(ConversationService.parseImagePromptCommand("/imagery"))
        XCTAssertNil(ConversationService.parseImagePromptCommand("/imageboard"))
        XCTAssertNil(ConversationService.parseImagePromptCommand("/imgur is great"))
    }

    func testUnrelatedSlashCommandsFallThrough() {
        XCTAssertNil(ConversationService.parseImagePromptCommand("/help"))
        XCTAssertNil(ConversationService.parseImagePromptCommand("/clear"))
        XCTAssertNil(ConversationService.parseImagePromptCommand(""))
    }

    func testPrefixWithoutTrailingSpaceFallsThrough() {
        // `/imagecat` is NOT a valid invocation — the space between
        // prefix and body is part of the contract.
        XCTAssertNil(ConversationService.parseImagePromptCommand("/imagecat"))
    }

    // MARK: - Flag parsing (parseImageCommand)

    func testStepsFlagExtractedAndPromptCleaned() {
        let result = ConversationService.parseImageCommand("/image --steps 30 a fox")
        XCTAssertEqual(result?.prompt, "a fox")
        XCTAssertEqual(result?.steps, 30)
        XCTAssertNil(result?.guidanceScale)
    }

    func testGuidanceFlagExtractedAndPromptCleaned() {
        let result = ConversationService.parseImageCommand("/image --guidance 9.0 a fox")
        XCTAssertEqual(result?.prompt, "a fox")
        XCTAssertEqual(result?.guidanceScale, 9.0)
        XCTAssertNil(result?.steps)
    }

    func testBothFlagsExtractedInOrder() {
        let result = ConversationService.parseImageCommand("/image --steps 30 --guidance 9.0 a fox")
        XCTAssertEqual(result?.prompt, "a fox")
        XCTAssertEqual(result?.steps, 30)
        XCTAssertEqual(result?.guidanceScale, 9.0)
    }

    func testBothFlagsExtractedReversedOrder() {
        // Flag order shouldn't matter — the eater chews each token
        // until it sees something that isn't a known flag.
        let result = ConversationService.parseImageCommand("/image --guidance 9.0 --steps 30 a fox")
        XCTAssertEqual(result?.prompt, "a fox")
        XCTAssertEqual(result?.steps, 30)
        XCTAssertEqual(result?.guidanceScale, 9.0)
    }

    func testMalformedStepsValueStopsFlagEating() {
        // `--steps abc` is malformed: not an int. The eater stops
        // there and treats everything from `--steps` onwards as the
        // prompt body. Users who literally want to ask about
        // "--steps abc" can do so without being silently dropped.
        let result = ConversationService.parseImageCommand("/image --steps abc a fox")
        XCTAssertEqual(result?.prompt, "--steps abc a fox")
        XCTAssertNil(result?.steps)
    }

    func testOutOfRangeStepsStopsFlagEating() {
        // 200 steps is well past the 1...100 sanity range. We bail
        // the eater instead of silently clamping so the user can
        // immediately see their typo (the literal flag in the
        // prompt) rather than getting a different image than they
        // expected.
        let result = ConversationService.parseImageCommand("/image --steps 200 fox")
        XCTAssertEqual(result?.prompt, "--steps 200 fox")
        XCTAssertNil(result?.steps)
    }

    func testFlagsAfterPromptBodyAreTreatedAsProse() {
        // Once we see a non-flag token, the eater stops — flags
        // after the prompt body are part of the prompt verbatim.
        let result = ConversationService.parseImageCommand("/image a fox --steps 30")
        XCTAssertEqual(result?.prompt, "a fox --steps 30")
        XCTAssertNil(result?.steps)
    }

    func testOnlyFlagsWithNoBodyReturnsNil() {
        // `/image --steps 30` with no actual prompt body falls
        // through. The model is the better surface for "what did
        // you want me to draw?" — silently producing a blank image
        // is worse than the regular LLM saying "tell me what you
        // want."
        XCTAssertNil(ConversationService.parseImageCommand("/image --steps 30"))
    }

    func testParseImagePromptCommandStripsFlagsForLegacyCallers() {
        // The thin-wrapper `parseImagePromptCommand` returns only the
        // prompt body — callers that don't need flags (like the
        // watchdog-timeout decision) get a clean String.
        let prompt = ConversationService.parseImagePromptCommand("/image --steps 30 --guidance 9.0 a fox")
        XCTAssertEqual(prompt, "a fox")
    }
}
