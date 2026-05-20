import XCTest
@testable import HomeHub

/// Tests the pure surface of `WebSearchService`:
/// - `Hit` Equatable conformance (relied on by the result-diff path)
/// - `SearchError` localised descriptions (surface in chat as toast)
///
/// The actual HTTP path + cache go through URLSession.shared so they
/// aren't exercised here (avoid flaky network-dependent CI). The
/// caching semantics are validated transitively via Hit value
/// equality + cache-key construction reading.
final class WebSearchServiceTests: XCTestCase {

    // MARK: - Hit equatable

    func testHit_EqualForIdenticalFields() {
        let a = WebSearchService.Hit(title: "T", url: "https://x", snippet: "S")
        let b = WebSearchService.Hit(title: "T", url: "https://x", snippet: "S")
        XCTAssertEqual(a, b)
    }

    func testHit_NotEqualWhenAnyFieldDiffers() {
        let base = WebSearchService.Hit(title: "T", url: "https://x", snippet: "S")
        XCTAssertNotEqual(base, WebSearchService.Hit(title: "T2", url: "https://x", snippet: "S"))
        XCTAssertNotEqual(base, WebSearchService.Hit(title: "T",  url: "https://y", snippet: "S"))
        XCTAssertNotEqual(base, WebSearchService.Hit(title: "T",  url: "https://x", snippet: "S2"))
    }

    // MARK: - SearchError descriptions

    func testSearchError_InvalidURLLocalised() {
        let err = WebSearchService.SearchError.invalidURL
        XCTAssertNotNil(err.errorDescription)
        XCTAssertFalse(err.errorDescription?.isEmpty == true)
    }

    func testSearchError_RateLimitedHasCzechCopy() {
        let err = WebSearchService.SearchError.rateLimited
        // Sanity: the Czech localisation must mention DuckDuckGo by
        // name so the user understands which provider rate-limited.
        XCTAssertTrue(err.errorDescription?.contains("DuckDuckGo") == true)
    }

    func testSearchError_NetworkErrorWrapsUnderlying() {
        let underlying = URLError(.timedOut)
        let err = WebSearchService.SearchError.networkError(underlying)
        XCTAssertNotNil(err.errorDescription)
        XCTAssertTrue(err.errorDescription?.contains("Chyba sítě") == true)
    }

    // MARK: - searchStructured input validation
    //
    // Empty / whitespace queries throw `.invalidURL` BEFORE the URL
    // construction — this is a synchronous guard that doesn't touch
    // the network and is therefore safe to test in CI.

    func testSearchStructured_EmptyQueryThrowsInvalidURL() async {
        do {
            _ = try await WebSearchService.searchStructured(query: "", limit: 5)
            XCTFail("Empty query must throw")
        } catch let err as WebSearchService.SearchError {
            if case .invalidURL = err { /* ok */ } else {
                XCTFail("Expected .invalidURL, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSearchStructured_WhitespaceOnlyQueryThrowsInvalidURL() async {
        do {
            _ = try await WebSearchService.searchStructured(query: "   \n  ", limit: 5)
            XCTFail("Whitespace-only query must throw")
        } catch let err as WebSearchService.SearchError {
            if case .invalidURL = err { /* ok */ } else {
                XCTFail("Expected .invalidURL, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - parseHits (HTML parser)
    //
    // Regression coverage for the live DDG Lite markup. The parser
    // previously required `class` to appear before `href` inside the
    // anchor; DDG emits `href` first, so every search silently returned
    // zero hits. These fixtures lock in attribute-order independence.

    /// Realistic DDG Lite fragment: `href` precedes `class`, URLs are
    /// direct (no `/l/?uddg=` redirect), snippet sits in the next row.
    private var ddgLiteFixture: String {
        """
        <table>
          <tr><td>1.&nbsp;</td><td>
            <a rel="nofollow" href="https://github.com/ml-explore/mlx" class='result-link'>ml-explore/mlx</a>
          </td></tr>
          <tr><td>&nbsp;</td><td class='result-snippet'>MLX is an array framework for Apple silicon.</td></tr>
          <tr><td>2.&nbsp;</td><td>
            <a rel="nofollow" href="https://opensource.apple.com/projects/mlx/" class='result-link'>Apple MLX</a>
          </td></tr>
          <tr><td>&nbsp;</td><td class='result-snippet'>Open source machine learning on Apple devices.</td></tr>
        </table>
        """
    }

    func testParseHits_ExtractsTitleURLSnippet_HrefBeforeClass() {
        let hits = WebSearchService.parseHits(from: ddgLiteFixture, limit: 5)
        XCTAssertEqual(hits.count, 2, "Both result-link anchors must be parsed")
        XCTAssertEqual(hits[0].title, "ml-explore/mlx")
        XCTAssertEqual(hits[0].url, "https://github.com/ml-explore/mlx")
        XCTAssertEqual(hits[0].snippet, "MLX is an array framework for Apple silicon.")
        XCTAssertEqual(hits[1].url, "https://opensource.apple.com/projects/mlx/")
    }

    func testParseHits_StillWorksWhenClassBeforeHref() {
        // Defend against DDG flipping the order back — the parser must be
        // order-independent, not just tuned to today's markup.
        let html = "<a class='result-link' href='https://example.com'>Example</a>"
            + "<td class='result-snippet'>Snip</td>"
        let hits = WebSearchService.parseHits(from: html, limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].url, "https://example.com")
        XCTAssertEqual(hits[0].title, "Example")
    }

    func testParseHits_RespectsLimit() {
        let hits = WebSearchService.parseHits(from: ddgLiteFixture, limit: 1)
        XCTAssertEqual(hits.count, 1)
    }

    func testParseHits_EmptyHTMLYieldsNoHits() {
        XCTAssertTrue(WebSearchService.parseHits(from: "<html></html>", limit: 5).isEmpty)
    }
}
