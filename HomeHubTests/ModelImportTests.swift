import XCTest
@testable import HomeHub

/// Unit tests for the URL-handling helpers on `ModelDownloadService`
/// that drive `AddFromURLSheet`'s pre-flight UX.
///
/// We can't test `probeURL` itself without a network mock, but the
/// supporting helpers — name derivation, URL normalisation, and
/// upfront URL validation — have enough edge cases to be worth pinning
/// down here.
final class ModelImportTests: XCTestCase {

    // MARK: - suggestedName

    func testSuggestedNameStripsExtensionAndReplacesHyphens() {
        let url = URL(string: "https://huggingface.co/repo/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!
        XCTAssertEqual(
            ModelDownloadService.suggestedName(from: url),
            "Llama 3.2 3B Instruct Q4_K_M"
        )
    }

    func testSuggestedNameKeepsUnderscores() {
        // Underscores in quantisation labels (Q4_K_M, IQ3_XXS) should
        // survive — they're idiomatic, not separators.
        let url = URL(string: "https://example.com/Phi-3.5-mini-instruct-Q5_K_M.gguf")!
        XCTAssertEqual(
            ModelDownloadService.suggestedName(from: url),
            "Phi 3.5 mini instruct Q5_K_M"
        )
    }

    func testSuggestedNameReturnsNilForBareHost() {
        let url = URL(string: "https://huggingface.co/")!
        XCTAssertNil(ModelDownloadService.suggestedName(from: url))
    }

    // MARK: - normaliseModelURL

    func testNormaliseRewritesHuggingFaceBlobToResolve() {
        let raw = URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-GGUF/blob/main/file.gguf")!
        let result = ModelDownloadService.normaliseModelURL(raw)
        XCTAssertEqual(
            result.absoluteString,
            "https://huggingface.co/bartowski/Llama-3.2-3B-GGUF/resolve/main/file.gguf"
        )
    }

    func testNormaliseLeavesNonHuggingFaceURLsAlone() {
        let raw = URL(string: "https://example.com/blob/file.gguf")!
        XCTAssertEqual(ModelDownloadService.normaliseModelURL(raw), raw)
    }

    func testNormaliseLeavesAlreadyResolvedURLsAlone() {
        let raw = URL(string: "https://huggingface.co/repo/resolve/main/file.gguf")!
        XCTAssertEqual(ModelDownloadService.normaliseModelURL(raw), raw)
    }

    // MARK: - validateModelURL

    func testValidateRejectsHuggingFaceTreeListing() {
        let url = URL(string: "https://huggingface.co/repo/tree/main")!
        XCTAssertThrowsError(try ModelDownloadService.validateModelURL(url))
    }

    func testValidateRejectsJSONSidecar() {
        let url = URL(string: "https://example.com/model/config.json")!
        XCTAssertThrowsError(try ModelDownloadService.validateModelURL(url))
    }

    func testValidateRejectsSafetensors() {
        let url = URL(string: "https://example.com/model/weights.safetensors")!
        XCTAssertThrowsError(try ModelDownloadService.validateModelURL(url))
    }

    func testValidateAcceptsGGUFFile() {
        let url = URL(string: "https://example.com/repo/resolve/main/model.gguf")!
        XCTAssertNoThrow(try ModelDownloadService.validateModelURL(url))
    }

    // MARK: - Citations parser (ToolObservation)

    func testCitationsExtractsSingleURL() {
        let body = """
        Web results for "weather Prague" (via DuckDuckGo):
        1. Weather forecast
           Some snippet here.
           https://example.com/weather/prague
        """
        let obs = ToolObservation(body: body)
        XCTAssertEqual(obs.citations.map(\.url.absoluteString),
                       ["https://example.com/weather/prague"])
    }

    func testCitationsExtractsMultipleURLs() {
        let body = """
        1. Title A — https://a.example.com/path
        2. Title B — http://b.example.com/page?q=1
        3. Title C — https://c.example.com
        """
        let obs = ToolObservation(body: body)
        let urls = obs.citations.map(\.url.absoluteString)
        XCTAssertEqual(urls.count, 3)
        XCTAssertTrue(urls.contains("https://a.example.com/path"))
        XCTAssertTrue(urls.contains("http://b.example.com/page?q=1"))
        XCTAssertTrue(urls.contains("https://c.example.com"))
    }

    func testCitationsTrimsTrailingPunctuation() {
        let body = "See https://example.com/page. That's it."
        let obs = ToolObservation(body: body)
        XCTAssertEqual(obs.citations.map(\.url.absoluteString),
                       ["https://example.com/page"])
    }

    func testCitationsDeduplicatesIdenticalURLs() {
        let body = """
        First mention: https://example.com/page
        Same again:    https://example.com/page
        """
        let obs = ToolObservation(body: body)
        XCTAssertEqual(obs.citations.count, 1)
    }

    func testCitationsCapsAtFive() {
        let body = (1...10).map { "https://site\($0).example.com/" }.joined(separator: "\n")
        let obs = ToolObservation(body: body)
        XCTAssertEqual(obs.citations.count, 5)
    }

    func testCitationsIgnoresPlainText() {
        let body = "No links in this string at all, just words."
        let obs = ToolObservation(body: body)
        XCTAssertEqual(obs.citations, [])
    }

    func testCitationHostMatchesURL() {
        let body = "https://www.duckduckgo.com/some/path"
        let obs = ToolObservation(body: body)
        let citation = obs.citations.first
        XCTAssertEqual(citation?.host, "www.duckduckgo.com")
    }
}
