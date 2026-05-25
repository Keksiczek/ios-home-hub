import XCTest
@testable import HomeHub

/// Coverage for the body parser hooks on `ToolObservation` —
/// `inferredToolName`, `isEmptyResult`, and citation extraction.
/// These run pure on the persisted body string so no async setup is
/// needed.
final class ToolObservationTests: XCTestCase {

    private func make(_ body: String) -> ToolObservation {
        ToolObservation(body: body)
    }

    // MARK: - inferredToolName

    func testWebSearchResultsAreClassifiedCorrectly() {
        let obs = make("""
            Web results for "weather Prague" (via DuckDuckGo):
            1. Prague forecast
               Partly cloudy 12°C
               https://weather.example/prague
            """)
        XCTAssertEqual(obs.inferredToolName, "WebSearch")
    }

    func testWebSearchEmptyIsClassifiedAsWebSearch() {
        let obs = make("""
            No results for "asdfgh qwerty" (via DuckDuckGo).
            Try again with different keywords ...
            """)
        XCTAssertEqual(obs.inferredToolName, "WebSearch")
    }

    func testFetchPageResultIsClassifiedAsFetchPage() {
        let obs = make("""
            FetchPage https://example.com/article:
            Title: Example Article

            Body text here.
            """)
        XCTAssertEqual(obs.inferredToolName, "FetchPage")
    }

    func testFetchPageRefusalIsClassifiedAsFetchPage() {
        let obs = make("Refused to fetch 192.168.1.1: private / loopback / metadata addresses are not allowed.")
        XCTAssertEqual(obs.inferredToolName, "FetchPage")
        XCTAssertTrue(obs.isEmptyResult)
    }

    func testFetchPageFailureIsClassifiedAsFetchPage() {
        let obs = make("Could not fetch https://example.com/: HTTP 404.")
        XCTAssertEqual(obs.inferredToolName, "FetchPage")
        XCTAssertTrue(obs.isEmptyResult)
    }

    func testUnknownToolFallsBack() {
        let obs = make("Some calculator output: 42")
        XCTAssertEqual(obs.inferredToolName, "Tool")
    }

    // MARK: - isError vs isEmptyResult

    func testToolErrorEnvelopeFlaggedAsError() {
        let obs = make("[tool error: invalid input] expected URL, got 'nope'")
        XCTAssertTrue(obs.isError)
        XCTAssertFalse(obs.isEmptyResult)
    }

    func testEmptyWebResultNotError() {
        let obs = make("No results for \"abc\" (via DuckDuckGo).\nTry again ...")
        XCTAssertFalse(obs.isError)
        XCTAssertTrue(obs.isEmptyResult)
    }

    func testNormalResultIsNeitherErrorNorEmpty() {
        let obs = make("""
            Web results for "x":
            1. Title
               https://example.com
            """)
        XCTAssertFalse(obs.isError)
        XCTAssertFalse(obs.isEmptyResult)
    }

    // MARK: - Structured citations

    func testCitationsParsedFromStructuredWebSearch() {
        let obs = make("""
            Web results for "weather Prague" (via DuckDuckGo):
            1. Current Weather in Prague
               Partly cloudy 12°C
               https://weather.example/prague
            2. Prague 10-day Forecast
               Light rain expected
               https://weather.example/forecast
            """)
        let citations = obs.citations
        XCTAssertEqual(citations.count, 2)
        XCTAssertEqual(citations[0].title, "Current Weather in Prague")
        XCTAssertEqual(citations[0].url.absoluteString, "https://weather.example/prague")
        XCTAssertEqual(citations[1].title, "Prague 10-day Forecast")
    }

    func testCitationsFallBackToBareURLWhenUnstructured() {
        let obs = make("Plain text with https://example.com/foo in the middle.")
        let citations = obs.citations
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations[0].url.absoluteString, "https://example.com/foo")
        XCTAssertNil(citations[0].title)
    }

    func testCitationStripsTrailingPunctuationFromBareURLs() {
        let obs = make("See https://example.com/foo, also https://example.com/bar.")
        let citations = obs.citations
        XCTAssertEqual(citations.count, 2)
        XCTAssertFalse(citations[0].url.absoluteString.hasSuffix(","))
        XCTAssertFalse(citations[1].url.absoluteString.hasSuffix("."))
    }

    func testCitationsCappedAtFive() {
        let body = (1...10).map { "https://example.com/\($0)" }.joined(separator: " ")
        let obs = make(body)
        XCTAssertEqual(obs.citations.count, 5)
    }
}

/// Coverage for `ToolPresenter.style(for:)` — the per-tool icon/label
/// lookup used by both the inline chip and the post-run result card.
final class ToolPresenterTests: XCTestCase {

    func testWebSearchStyle() {
        let style = ToolPresenter.style(for: "WebSearch")
        XCTAssertEqual(style.systemImage, "magnifyingglass")
        XCTAssertTrue(style.runningLabel.contains("Hledám"))
    }

    func testFetchPageStyle() {
        let style = ToolPresenter.style(for: "FetchPage")
        XCTAssertEqual(style.systemImage, "doc.text.viewfinder")
    }

    func testCaseInsensitiveLookup() {
        XCTAssertEqual(
            ToolPresenter.style(for: "websearch").systemImage,
            ToolPresenter.style(for: "WebSearch").systemImage
        )
    }

    func testSnakeCaseLookup() {
        // Some models emit `web_search` instead of `WebSearch`.
        XCTAssertEqual(
            ToolPresenter.style(for: "web_search").systemImage,
            ToolPresenter.style(for: "WebSearch").systemImage
        )
    }

    func testUnknownToolFallsBackToWrench() {
        let style = ToolPresenter.style(for: "TotallyMadeUpSkill")
        XCTAssertEqual(style.systemImage, "wrench.and.screwdriver.fill")
        XCTAssertTrue(style.runningLabel.contains("TotallyMadeUpSkill"))
    }
}
