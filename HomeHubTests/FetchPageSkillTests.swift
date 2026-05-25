import XCTest
@testable import HomeHub

/// Coverage for `FetchPageSkill` — focused on the three units that are
/// pure-function and testable without network I/O:
///
///   * `normaliseURL`: scheme promotion, scheme reject, host empty
///   * `isBlockedHost`: SSRF allowlist — the security-critical one
///   * `htmlToText`: entity decoding, tag stripping, truncation
///
/// `execute(input:)` itself isn't tested here — it touches
/// `URLSession.shared.data(for:)` which would need a fake URLProtocol
/// or a network record/replay setup the rest of the project doesn't
/// have yet. The two helper functions cover the logic that decides
/// *whether* the network call happens, which is the part of the skill
/// that can fail open.
final class FetchPageSkillTests: XCTestCase {

    // MARK: - normaliseURL

    func testNormaliseURLAcceptsHTTPS() {
        let url = FetchPageSkill.normaliseURL("https://example.com/article")
        XCTAssertEqual(url?.absoluteString, "https://example.com/article")
    }

    func testNormaliseURLAcceptsHTTP() {
        let url = FetchPageSkill.normaliseURL("http://example.com")
        XCTAssertEqual(url?.absoluteString, "http://example.com")
    }

    func testNormaliseURLPromotesBareHostToHTTPS() {
        let url = FetchPageSkill.normaliseURL("example.com/foo")
        XCTAssertEqual(url?.absoluteString, "https://example.com/foo")
    }

    func testNormaliseURLRejectsFileScheme() {
        XCTAssertNil(FetchPageSkill.normaliseURL("file:///etc/passwd"))
    }

    func testNormaliseURLRejectsJavaScriptScheme() {
        XCTAssertNil(FetchPageSkill.normaliseURL("javascript:alert(1)"))
    }

    func testNormaliseURLRejectsEmpty() {
        XCTAssertNil(FetchPageSkill.normaliseURL(""))
    }

    func testNormaliseURLIsCaseInsensitiveForScheme() {
        // Some agentic-loop outputs upcase the scheme. Accept it.
        let url = FetchPageSkill.normaliseURL("HTTPS://Example.COM/X")
        XCTAssertNotNil(url)
    }

    // MARK: - isBlockedHost (SSRF guard — security-critical)
    //
    // Each "blocks" assertion below corresponds to a real exfiltration
    // vector. If any of these regress to `false`, FetchPage opens that
    // class of address back up to prompt-injection attackers.

    func testBlocksLocalhostHostname() {
        XCTAssertTrue(FetchPageSkill.isBlockedHost("localhost"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("LOCALHOST"))   // case
        XCTAssertTrue(FetchPageSkill.isBlockedHost("ip6-localhost"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("ip6-loopback"))
    }

    func testBlocksLoopbackIPv4() {
        XCTAssertTrue(FetchPageSkill.isBlockedHost("127.0.0.1"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("127.0.0.2"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("127.255.255.255"))
    }

    func testBlocksLoopbackIPv6() {
        XCTAssertTrue(FetchPageSkill.isBlockedHost("::1"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("[::1]"))
    }

    func testBlocksAllZerosIPv4() {
        XCTAssertTrue(FetchPageSkill.isBlockedHost("0.0.0.0"))
    }

    func testBlocksRFC1918Class10() {
        XCTAssertTrue(FetchPageSkill.isBlockedHost("10.0.0.1"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("10.255.255.255"))
    }

    func testBlocksRFC1918Class192_168() {
        XCTAssertTrue(FetchPageSkill.isBlockedHost("192.168.0.1"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("192.168.1.1"))   // typical router admin
        XCTAssertTrue(FetchPageSkill.isBlockedHost("192.168.255.255"))
    }

    func testBlocksRFC1918Class172() {
        // Block range is 172.16.0.0 – 172.31.255.255. Verify both ends.
        XCTAssertTrue(FetchPageSkill.isBlockedHost("172.16.0.1"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("172.20.1.1"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("172.31.255.254"))
    }

    func testAllowsAdjacent172RangesThatAreNotPrivate() {
        // 172.15.x.x and 172.32.x.x are public ranges. The prefix list
        // is exhaustive for 172.16–31 only — verify the boundaries don't
        // over-block.
        XCTAssertFalse(FetchPageSkill.isBlockedHost("172.15.0.1"))
        XCTAssertFalse(FetchPageSkill.isBlockedHost("172.32.0.1"))
    }

    func testBlocksLinkLocalIPv4() {
        XCTAssertTrue(FetchPageSkill.isBlockedHost("169.254.0.1"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("169.254.169.254"))   // cloud metadata
    }

    func testBlocksLinkLocalIPv6() {
        XCTAssertTrue(FetchPageSkill.isBlockedHost("fe80::1"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("fe80::abcd:1234"))
    }

    func testBlocksUniqueLocalIPv6() {
        XCTAssertTrue(FetchPageSkill.isBlockedHost("fc00::1"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("fd12:3456::1"))
    }

    func testBlocksCloudMetadataHostnames() {
        XCTAssertTrue(FetchPageSkill.isBlockedHost("metadata.google.internal"))
        XCTAssertTrue(FetchPageSkill.isBlockedHost("metadata"))
    }

    func testAllowsPublicHosts() {
        // Coverage: typical search hits should pass through cleanly.
        // If any of these false-positive, the block rules are too broad.
        XCTAssertFalse(FetchPageSkill.isBlockedHost("example.com"))
        XCTAssertFalse(FetchPageSkill.isBlockedHost("en.wikipedia.org"))
        XCTAssertFalse(FetchPageSkill.isBlockedHost("www.weather.com"))
        XCTAssertFalse(FetchPageSkill.isBlockedHost("api.github.com"))
        XCTAssertFalse(FetchPageSkill.isBlockedHost("duckduckgo.com"))
        // Public IPs outside any blocked range.
        XCTAssertFalse(FetchPageSkill.isBlockedHost("8.8.8.8"))
        XCTAssertFalse(FetchPageSkill.isBlockedHost("1.1.1.1"))
    }

    func testAllowsHostsThatLookSimilarButAreNotPrivate() {
        // Sanity: `127example.com` would naively prefix-match `127.`
        // — make sure the prefix uses the dot separator correctly.
        XCTAssertFalse(FetchPageSkill.isBlockedHost("127example.com"))
        XCTAssertFalse(FetchPageSkill.isBlockedHost("10example.com"))
        // `feline.com` starts with `fe` but not `fe80:` or `fc00:`.
        XCTAssertFalse(FetchPageSkill.isBlockedHost("feline.com"))
    }

    // MARK: - htmlToText

    func testHtmlToTextStripsBasicTags() {
        let html = "<p>Hello <b>world</b>.</p>"
        let text = FetchPageSkill.htmlToText(html, byteCap: 1000)
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("world"))
        XCTAssertFalse(text.contains("<"))
        XCTAssertFalse(text.contains(">"))
    }

    func testHtmlToTextStripsScriptBlocks() {
        let html = """
            <p>Visible.</p>
            <script>alert('hidden')</script>
            <p>Also visible.</p>
            """
        let text = FetchPageSkill.htmlToText(html, byteCap: 1000)
        XCTAssertTrue(text.contains("Visible"))
        XCTAssertTrue(text.contains("Also visible"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("hidden"))
    }

    func testHtmlToTextStripsStyleBlocks() {
        let html = "<style>body{color:red}</style><p>Hi.</p>"
        let text = FetchPageSkill.htmlToText(html, byteCap: 1000)
        XCTAssertTrue(text.contains("Hi"))
        XCTAssertFalse(text.contains("color"))
    }

    func testHtmlToTextDecodesCommonEntities() {
        let html = "<p>Tom &amp; Jerry &lt;3 &mdash; the &quot;classic&quot;</p>"
        let text = FetchPageSkill.htmlToText(html, byteCap: 1000)
        XCTAssertTrue(text.contains("Tom & Jerry"))
        XCTAssertTrue(text.contains("<3"))
        XCTAssertTrue(text.contains("—"))
        XCTAssertTrue(text.contains("\"classic\""))
    }

    func testHtmlToTextDecodesNumericEntities() {
        let html = "<p>caf&#233; au lait</p>"   // é = U+00E9 = 233
        let text = FetchPageSkill.htmlToText(html, byteCap: 1000)
        XCTAssertTrue(text.contains("café"))
    }

    func testHtmlToTextPreservesParagraphBreaks() {
        let html = "<p>First.</p><p>Second.</p>"
        let text = FetchPageSkill.htmlToText(html, byteCap: 1000)
        // Block-element opener becomes a newline; we don't insist on
        // any specific number, just that the two paragraphs aren't
        // concatenated into one line.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThanOrEqual(lines.count, 2)
    }

    func testHtmlToTextTruncatesAtByteCapOnWordBoundary() {
        // 800 chars of plain words, byteCap = 50. Truncation should
        // land on a space and append "…", not slice mid-word.
        let html = "<p>" + Array(repeating: "lorem", count: 200).joined(separator: " ") + "</p>"
        let text = FetchPageSkill.htmlToText(html, byteCap: 50)
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertLessThan(text.utf8.count, 100)   // generous: cap + ellipsis byte cost
        // No mid-word slice: the last alphanumeric run should equal
        // the whole word "lorem", not a fragment of it.
        XCTAssertFalse(text.contains("lorem…"))   // trailing word must be complete
    }

    func testHtmlToTextHandlesEmptyInput() {
        XCTAssertEqual(FetchPageSkill.htmlToText("", byteCap: 100), "")
    }

    // MARK: - extractTitle

    func testExtractTitlePullsContents() {
        XCTAssertEqual(
            FetchPageSkill.extractTitle(from: "<html><head><title>Hello, World!</title></head></html>"),
            "Hello, World!"
        )
    }

    func testExtractTitleHandlesAttributes() {
        let html = "<title lang=\"en\">Page Title</title>"
        XCTAssertEqual(FetchPageSkill.extractTitle(from: html), "Page Title")
    }

    func testExtractTitleDecodesEntities() {
        XCTAssertEqual(
            FetchPageSkill.extractTitle(from: "<title>Q&amp;A</title>"),
            "Q&A"
        )
    }

    func testExtractTitleReturnsNilWhenAbsent() {
        XCTAssertNil(FetchPageSkill.extractTitle(from: "<html><body>No title here</body></html>"))
    }

    func testExtractTitleReturnsNilForEmptyTitle() {
        XCTAssertNil(FetchPageSkill.extractTitle(from: "<title></title>"))
        XCTAssertNil(FetchPageSkill.extractTitle(from: "<title>   </title>"))
    }

    // MARK: - extractMetaDescription

    func testExtractMetaPrefersOGDescription() {
        let html = """
            <head>
              <meta name="description" content="Generic description.">
              <meta property="og:description" content="Open Graph description.">
              <meta name="twitter:description" content="Twitter description.">
            </head>
            """
        XCTAssertEqual(
            FetchPageSkill.extractMetaDescription(from: html),
            "Open Graph description."
        )
    }

    func testExtractMetaFallsBackToTwitterDescription() {
        let html = """
            <head>
              <meta name="twitter:description" content="Twitter only.">
              <meta name="description" content="Generic.">
            </head>
            """
        XCTAssertEqual(
            FetchPageSkill.extractMetaDescription(from: html),
            "Twitter only."
        )
    }

    func testExtractMetaFallsBackToGenericDescription() {
        let html = """
            <head>
              <meta name="description" content="Just the generic one.">
            </head>
            """
        XCTAssertEqual(
            FetchPageSkill.extractMetaDescription(from: html),
            "Just the generic one."
        )
    }

    func testExtractMetaAcceptsReversedAttributeOrder() {
        // Some CMSes emit `content=` before `property=`. Must still match.
        let html = """
            <meta content="Reversed order works." property="og:description">
            """
        XCTAssertEqual(
            FetchPageSkill.extractMetaDescription(from: html),
            "Reversed order works."
        )
    }

    func testExtractMetaDecodesEntities() {
        let html = #"<meta property="og:description" content="Tom &amp; Jerry's adventure">"#
        XCTAssertEqual(
            FetchPageSkill.extractMetaDescription(from: html),
            "Tom & Jerry's adventure"
        )
    }

    func testExtractMetaReturnsNilWhenAbsent() {
        XCTAssertNil(FetchPageSkill.extractMetaDescription(from: "<html><body>no meta</body></html>"))
    }

    func testExtractMetaIgnoresUnrelatedMetas() {
        let html = """
            <meta name="viewport" content="width=device-width">
            <meta name="author" content="Someone">
            """
        XCTAssertNil(FetchPageSkill.extractMetaDescription(from: html))
    }

    // MARK: - extractOGImage

    private static let exampleBase = URL(string: "https://example.com/article")!

    func testExtractOGImagePullsAbsoluteURL() {
        let html = """
            <meta property="og:image" content="https://cdn.example.com/hero.jpg">
            """
        XCTAssertEqual(
            FetchPageSkill.extractOGImage(from: html, base: Self.exampleBase)?.absoluteString,
            "https://cdn.example.com/hero.jpg"
        )
    }

    func testExtractOGImageAcceptsReversedAttributeOrder() {
        let html = #"""
            <meta content="https://cdn.example.com/hero.jpg" property="og:image">
            """#
        XCTAssertEqual(
            FetchPageSkill.extractOGImage(from: html, base: Self.exampleBase)?.absoluteString,
            "https://cdn.example.com/hero.jpg"
        )
    }

    func testExtractOGImageResolvesPathRelative() {
        let html = """
            <meta property="og:image" content="/static/hero.jpg">
            """
        let resolved = FetchPageSkill.extractOGImage(from: html, base: Self.exampleBase)
        // The hero must end up on the page's host, not "" or a bare path.
        XCTAssertEqual(resolved?.host, "example.com")
        XCTAssertEqual(resolved?.path, "/static/hero.jpg")
    }

    func testExtractOGImageResolvesProtocolRelative() {
        let html = """
            <meta property="og:image" content="//cdn.example.com/hero.jpg">
            """
        XCTAssertEqual(
            FetchPageSkill.extractOGImage(from: html, base: Self.exampleBase)?.absoluteString,
            "https://cdn.example.com/hero.jpg"
        )
    }

    func testExtractOGImageFallsBackToTwitterImage() {
        let html = """
            <meta name="twitter:image" content="https://cdn.example.com/twitter.jpg">
            """
        XCTAssertEqual(
            FetchPageSkill.extractOGImage(from: html, base: Self.exampleBase)?.absoluteString,
            "https://cdn.example.com/twitter.jpg"
        )
    }

    func testExtractOGImageFallsBackToTwitterImageSrc() {
        // Older Twitter Card spec used `twitter:image:src` — many WordPress
        // themes still emit it. Must be picked up when no newer meta exists.
        let html = """
            <meta name="twitter:image:src" content="https://cdn.example.com/old.jpg">
            """
        XCTAssertEqual(
            FetchPageSkill.extractOGImage(from: html, base: Self.exampleBase)?.absoluteString,
            "https://cdn.example.com/old.jpg"
        )
    }

    func testExtractOGImagePrefersOGOverTwitter() {
        let html = """
            <meta property="og:image" content="https://cdn.example.com/og.jpg">
            <meta name="twitter:image" content="https://cdn.example.com/twitter.jpg">
            """
        XCTAssertEqual(
            FetchPageSkill.extractOGImage(from: html, base: Self.exampleBase)?.absoluteString,
            "https://cdn.example.com/og.jpg"
        )
    }

    func testExtractOGImageRejectsDataURI() {
        // `data:` URIs survive `URL(string:)` but the chip's AsyncImage
        // can't render them in this layout — reject so the chip skips
        // the thumbnail row entirely.
        let html = #"""
            <meta property="og:image" content="data:image/png;base64,AAAA">
            """#
        XCTAssertNil(FetchPageSkill.extractOGImage(from: html, base: Self.exampleBase))
    }

    func testExtractOGImageReturnsNilWhenAbsent() {
        let html = "<meta name='description' content='No image here.'>"
        XCTAssertNil(FetchPageSkill.extractOGImage(from: html, base: Self.exampleBase))
    }
}
