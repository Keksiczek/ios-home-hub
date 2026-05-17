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
}
