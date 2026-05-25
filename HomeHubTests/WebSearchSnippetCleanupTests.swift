import XCTest
@testable import HomeHub

/// Coverage for `WebSearchService.stripChrome` — the small whitelist
/// that drops DDG Lite UI-helper lines from snippets so the model
/// sees clean content. Exact-prefix matching is deliberate; verify
/// both that real chrome gets dropped and that legitimate snippets
/// survive intact.
final class WebSearchSnippetCleanupTests: XCTestCase {

    func testRealSnippetSurvives() {
        let snippet = "Prague is the capital and largest city of the Czech Republic …"
        XCTAssertEqual(WebSearchService.stripChrome(from: snippet), snippet)
    }

    func testShowMoreEnginesIsDropped() {
        XCTAssertEqual(
            WebSearchService.stripChrome(from: "Show more search engines"),
            ""
        )
    }

    func testLookingForEnglishIsDropped() {
        XCTAssertEqual(
            WebSearchService.stripChrome(from: "Looking for results in English?"),
            ""
        )
    }

    func testDidYouMeanIsDropped() {
        XCTAssertEqual(
            WebSearchService.stripChrome(from: "Did you mean: weather Prague"),
            ""
        )
    }

    func testCaseInsensitiveChrome() {
        XCTAssertEqual(
            WebSearchService.stripChrome(from: "LOOKING FOR RESULTS IN ENGLISH"),
            ""
        )
    }

    func testEmptySnippetReturnsEmpty() {
        XCTAssertEqual(WebSearchService.stripChrome(from: ""), "")
        XCTAssertEqual(WebSearchService.stripChrome(from: "   \n  "), "")
    }

    func testSnippetContainingChromeMidSentenceSurvives() {
        // Prefix match is deliberate — we don't want to drop a real
        // snippet that *contains* "Looking for" mid-sentence.
        let snippet = "Article: Looking for a hotel in Prague? Here's our top 10."
        XCTAssertEqual(WebSearchService.stripChrome(from: snippet), snippet)
    }

    func testWhitespaceAroundChromeStillDropped() {
        XCTAssertEqual(
            WebSearchService.stripChrome(from: "  Show more search engines  "),
            ""
        )
    }
}
