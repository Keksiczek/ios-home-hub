import XCTest
@testable import HomeHub

/// Tests for `ModelRouter.classify(userInput:hasImageAttachment:)`.
///
/// The classifier is the pure-function half of `ModelRouter` and the
/// only piece that needs unit coverage — resolution depends on
/// catalog state and lives behind the @MainActor-isolated instance
/// API, which is integration-level concern.
///
/// We pin the classifier's contract because it affects every chat
/// turn under `.automatic` / `.experimental` policy:
///   - greetings + short follow-ups → FAST (cheap warm-up)
///   - default conversational input → BALANCED (the workhorse)
///   - code, long-form prompts, depth-asking phrases → SMART
///   - vision attachments → BALANCED (the resolver then picks a
///     VLM-capable model regardless of tier; we don't bump to SMART
///     because the smallest VLM in the catalog (SmolVLM 256M) is
///     fast and almost always sufficient for image questions)
final class ModelRouterClassifyTests: XCTestCase {

    // MARK: - FAST tier (short conversational)

    func testGreetingsRouteToFast() {
        XCTAssertEqual(ModelRouter.classify(userInput: "ahoj", hasImageAttachment: false), .fast)
        XCTAssertEqual(ModelRouter.classify(userInput: "díky!", hasImageAttachment: false), .fast)
        XCTAssertEqual(ModelRouter.classify(userInput: "ok", hasImageAttachment: false), .fast)
        XCTAssertEqual(ModelRouter.classify(userInput: "co tím myslíš?", hasImageAttachment: false), .fast)
    }

    func testShortFollowUpRoutesToFast() {
        XCTAssertEqual(
            ModelRouter.classify(userInput: "a co dál", hasImageAttachment: false),
            .fast
        )
    }

    func testEmptyInputRoutesToFast() {
        // Defensive: a degenerate empty input shouldn't blow up the
        // classifier. The router resolver would then likely return
        // nil because no model is picked; that's fine — caller
        // surfaces an actionable error.
        XCTAssertEqual(ModelRouter.classify(userInput: "", hasImageAttachment: false), .fast)
        XCTAssertEqual(ModelRouter.classify(userInput: "   ", hasImageAttachment: false), .fast)
    }

    // MARK: - SMART tier (code, long, depth-asking)

    func testTripleBackticksAlwaysSmart() {
        // Triple backticks are the universal "I'm sending code"
        // signal — even a 5-char prompt with them goes to SMART.
        XCTAssertEqual(
            ModelRouter.classify(userInput: "```swift\nlet x = 1\n```", hasImageAttachment: false),
            .smart
        )
        // Markers within longer prose still trigger SMART.
        XCTAssertEqual(
            ModelRouter.classify(userInput: "co to dělá: ```let f = { $0 + 1 }```", hasImageAttachment: false),
            .smart
        )
    }

    func testCodeLanguageMarkersRouteToSmart() {
        let codePrompts = [
            "func foo() { return 1 }",
            "def bar(x): return x + 1",
            "class Animal { var name: String }",
            "import Foundation",
            "fun add(a: Int, b: Int) = a + b",
            "<script>alert('x')</script>",
            "SELECT * FROM users WHERE id = 1",
            "git rebase -i HEAD~3",
            "npm install --save-dev typescript"
        ]
        for prompt in codePrompts {
            XCTAssertEqual(
                ModelRouter.classify(userInput: prompt, hasImageAttachment: false),
                .smart,
                "Expected SMART for code-marker prompt: \(prompt)"
            )
        }
    }

    func testStacktraceLikeInputRoutesToSmart() {
        // Crash logs / stack traces are the canonical "I need
        // serious reasoning" prompt. The classifier picks up
        // "stacktrace", "traceback", and "Exception:" markers.
        let stacktrace = """
        Traceback (most recent call last):
          File "x.py", line 12, in foo
            return bar(x)
        Exception: invalid input
        """
        XCTAssertEqual(
            ModelRouter.classify(userInput: stacktrace, hasImageAttachment: false),
            .smart
        )
    }

    func testLongPromptRoutesToSmart() {
        // Over 500 chars of plain text → SMART regardless of shape.
        let long = String(repeating: "Toto je dlouhá otázka, která potřebuje hlubší zpracování. ", count: 12)
        XCTAssertGreaterThan(long.count, 500)
        XCTAssertEqual(
            ModelRouter.classify(userInput: long, hasImageAttachment: false),
            .smart
        )
    }

    func testDepthMarkersRouteToSmart() {
        // Even a short prompt with explicit depth markers wants
        // the bigger model. Mix of Czech + English to cover both
        // localisations.
        let depthPrompts = [
            "vysvětli detailně proč nebe je modré",
            "explain in detail how transformers work",
            "step by step jak nainstalovat docker",
            "porovnej Swift a Rust ohledně paměti",
            "analyze this dataset"
        ]
        for prompt in depthPrompts {
            XCTAssertEqual(
                ModelRouter.classify(userInput: prompt, hasImageAttachment: false),
                .smart,
                "Expected SMART for depth-marker prompt: \(prompt)"
            )
        }
    }

    // MARK: - BALANCED tier (default)

    func testTypicalQuestionRoutesToBalanced() {
        // 60–500 chars, no code markers, no depth phrases — the
        // workhorse path.
        //
        // Every fixture here must actually exceed 60 characters. The
        // original four were 40–55 chars, so they all hit the
        // `charCount < 60 → .fast` gate and never reached the
        // `.balanced` default this test claims to cover — the test
        // was asserting against a band it never entered.
        let prompts = [
            "Můžeš mi doporučit nějakou dobrou knihu o psychologii pro začátečníky?",
            "Jaký je dnes večer program v Národním divadle a seženu ještě lístek?",
            "What is the practical difference between an ETF and a mutual fund?",
            "Jak se připravuje pravá italská carbonara bez smetany a bez zbytečností?"
        ]
        for prompt in prompts {
            XCTAssertGreaterThan(
                prompt.count, 60,
                "Fixture must exceed the 60-char fast-path gate to exercise .balanced: \(prompt)"
            )
        }
        for prompt in prompts {
            XCTAssertEqual(
                ModelRouter.classify(userInput: prompt, hasImageAttachment: false),
                .balanced,
                "Expected BALANCED for conversational prompt: \(prompt)"
            )
        }
    }

    // MARK: - Vision (attachment override)

    func testImageAttachmentRoutesToBalancedRegardlessOfText() {
        // The vision-attached case routes to BALANCED tier at the
        // classifier level; the resolver then picks the smallest
        // installed VLM regardless of tier. We deliberately don't
        // bump to SMART because the smallest VLM (SmolVLM 256M)
        // is fast and almost always sufficient.
        XCTAssertEqual(
            ModelRouter.classify(userInput: "co je na obrázku?", hasImageAttachment: true),
            .balanced
        )
        // Even when the prompt itself would normally be SMART
        // (depth phrase), an image attachment dominates because
        // the bottleneck shifts to "do we have a VLM at all?".
        XCTAssertEqual(
            ModelRouter.classify(userInput: "vysvětli detailně co to je", hasImageAttachment: true),
            .balanced
        )
    }

    // MARK: - Edge cases

    func testCaseInsensitiveMarkerMatch() {
        // Code + depth markers should match regardless of input
        // case. The classifier normalises via `.lowercased()`.
        XCTAssertEqual(
            ModelRouter.classify(userInput: "FUNC FOO() { RETURN 1 }", hasImageAttachment: false),
            .smart
        )
        XCTAssertEqual(
            ModelRouter.classify(userInput: "VYSVĚTLI DETAILNĚ kvantovou fyziku", hasImageAttachment: false),
            .smart
        )
    }

    func testWhitespaceOnlyDoesNotMatchCodeMarkers() {
        // Regression: an early version had "func " match as a
        // substring even inside English prose ("the func is gone").
        // We rely on the marker including its trailing space so
        // common words like "funcs" or sentences ending in "func."
        // don't trigger. This test pins the boundary.
        //
        // The sentence is deliberately over 60 characters. The original
        // was 21, which returned `.fast` via the length gate before the
        // code markers were ever consulted — so it asserted `.balanced`
        // while proving nothing about substring matching. Long enough to
        // clear the gate, the assertion actually tests what it claims.
        let prompt = "mám tu funci na ulici a chtěl bych vědět, jestli to má vůbec smysl"
        XCTAssertGreaterThan(prompt.count, 60)
        XCTAssertEqual(
            ModelRouter.classify(userInput: prompt, hasImageAttachment: false),
            .balanced
        )
    }
}
