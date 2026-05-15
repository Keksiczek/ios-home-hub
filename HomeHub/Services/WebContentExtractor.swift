import Foundation
import os

/// First realistic URL → readable-text extractor for the Knowledge Base
/// ingest pipeline.
///
/// ## What this is
/// A minimal, dependency-free HTML→text pass. Fetches the page with a
/// browser-shaped User-Agent (DDG / Cloudflare reject `curl/8`), strips
/// `<script>` / `<style>` blocks wholesale, removes the remaining tags,
/// decodes the dozen entity references HTML actually uses in 95 % of
/// pages, and collapses whitespace into a readable body. Captures
/// `<title>` separately so callers can replace a generic share title
/// with the page's own.
///
/// ## What this is NOT
/// - A reader-mode like Safari Reader. We make no attempt to find
///   "the article" inside cluttered pages — boilerplate (nav, footer,
///   sidebar) leaks through. Acceptable for a v1 because the
///   downstream embedding pipeline tolerates noise.
/// - A JS renderer. Single-page apps that paint content after
///   page-load via JavaScript will produce near-empty extracts.
///   Surface this case explicitly via `ExtractionError.emptyContent`
///   so the ingest pipeline can mark the document failed.
/// - A crawler. One URL, one fetch, no following links.
///
/// ## Robustness choices
/// - 10-second timeout — Knowledge Base ingest doesn't run on a hot
///   path so we can afford a generous timeout, but anything longer
///   is almost always a stalled connection.
/// - Content-Type must contain `text/html` or `application/xhtml`.
///   Anything else (PDF, image, JSON API) returns
///   `ExtractionError.unsupportedContentType` — the right path for
///   those types is the file-import pipeline, not this extractor.
/// - Body size cap (4 MB) protects against accidentally downloading
///   a multi-GB SPA bundle masquerading as HTML.
enum WebContentExtractor {

    /// Plain-text projection of a single HTML page.
    struct Page: Sendable, Equatable {
        /// Page `<title>` when present and non-empty.
        let title: String?
        /// HTML→text body. Whitespace-collapsed.
        let plainText: String
        /// Canonical URL the server actually served (after redirects).
        /// Stored so the document record can quote the final URL — the
        /// user may have shared a t.co / news.ycombinator redirect.
        let finalURL: URL
        /// Length of the fetched response body, in bytes. Surfaced in
        /// logs for "why is extraction empty" debugging.
        let fetchedBytes: Int
        /// Which heuristic produced `plainText`. One of:
        ///   * `"article"` — `<article>` element won.
        ///   * `"main"` — `<main>` element won.
        ///   * `"role=main"` — element with `role="main"` won.
        ///   * `"densest"` — fell through to text-density pick.
        ///   * `"whole-body"` — no container heuristic produced enough
        ///     text; rendered the whole `<body>` through the block
        ///     emitter.
        ///   * `"body-fallback"` — reader pass too short, fell back to
        ///     the legacy regex strip of the entire body.
        let extractionPath: String
    }

    enum ExtractionError: Error, LocalizedError {
        case invalidURL
        case unsupportedScheme(String)
        case network(Error)
        case badStatus(Int)
        case unsupportedContentType(String)
        case tooLarge(bytes: Int)
        case decodingFailed
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "URL je neplatná."
            case .unsupportedScheme(let s):
                return "URL používá nepodporované schéma '\(s)'. Podporujeme http(s)."
            case .network(let err):
                return "Stahování stránky selhalo: \(err.localizedDescription)"
            case .badStatus(let code):
                return "Server vrátil HTTP \(code). Stránka může vyžadovat přihlášení nebo neexistuje."
            case .unsupportedContentType(let ct):
                let trimmed = ct.isEmpty ? "(none)" : ct
                return "URL nevrací HTML stránku (Content-Type: \(trimmed)). Pro import jiných typů použij soubor."
            case .tooLarge(let bytes):
                let mb = bytes / (1024 * 1024)
                return "Stránka je příliš velká (\(mb) MB). Limit je 4 MB."
            case .decodingFailed:
                return "Tělo stránky se nepodařilo dekódovat jako text."
            case .emptyContent:
                return "Ze stránky se nepodařilo extrahovat žádný čitelný text. Možná jde o JavaScript-renderovaný web — pro takové stránky zatím nemáme renderer."
            }
        }
    }

    private static let timeout: TimeInterval = 10
    private static let maxBytes: Int = 4 * 1024 * 1024
    /// Below this many characters after stripping, treat as "empty"
    /// — single-page apps that render via JS produce a few dozen
    /// chars (nav links, `noscript` notice). Marking those failed
    /// keeps junk out of the index.
    private static let minExtractedChars = 200

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 " +
        "Mobile/15E148 Safari/604.1"

    private static let log = Logger(subsystem: "cz.keksiczek.homehub", category: "WebContentExtractor")

    /// Fetches the URL and projects the response into a `Page`. All
    /// failure modes are typed; the caller decides whether to fail
    /// the ingest job, render a banner, etc.
    static func fetch(_ url: URL) async throws -> Page {
        guard let scheme = url.scheme?.lowercased() else {
            throw ExtractionError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw ExtractionError.unsupportedScheme(scheme)
        }

        log.info("fetch start: \(url.absoluteString, privacy: .public)")

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            log.error("fetch network failed: \(url.absoluteString, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            throw ExtractionError.network(error)
        }

        let http = response as? HTTPURLResponse
        let finalURL = response.url ?? url
        if let http {
            guard (200..<300).contains(http.statusCode) else {
                log.error("fetch bad status \(http.statusCode, privacy: .public) for \(url.absoluteString, privacy: .public)")
                throw ExtractionError.badStatus(http.statusCode)
            }
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            // Content-Type can be `text/html; charset=utf-8` — just
            // substring-match the prefix. Some servers omit the
            // header entirely; assume HTML in that case rather than
            // bouncing the user, but log it so we can spot trends.
            if !ct.isEmpty,
               !ct.contains("text/html"),
               !ct.contains("application/xhtml") {
                log.error("fetch unsupported content-type '\(ct, privacy: .public)' for \(url.absoluteString, privacy: .public)")
                throw ExtractionError.unsupportedContentType(ct)
            }
            if ct.isEmpty {
                log.notice("fetch missing Content-Type for \(url.absoluteString, privacy: .public) — proceeding")
            }
        }

        guard data.count <= maxBytes else {
            throw ExtractionError.tooLarge(bytes: data.count)
        }

        // Decoding order: declared charset (rare in practice) → UTF-8
        // → ISO-Latin-1 (won't error on any byte sequence, so it's
        // the always-succeeds fallback for the rare windows-1252
        // page that hasn't moved to UTF-8 yet). NSAttributedString's
        // HTML reader is intentionally avoided — it must run on the
        // main thread, allocates a WebKit text system, and has a
        // long history of perf and crash issues for arbitrary input.
        let html: String
        if let utf8 = String(data: data, encoding: .utf8) {
            html = utf8
        } else if let latin = String(data: data, encoding: .isoLatin1) {
            html = latin
        } else {
            throw ExtractionError.decodingFailed
        }

        let title = extractTitle(from: html)

        // Reader-style extraction: find the densest article-like
        // container, emit headings + paragraphs + list items in
        // document order. Keeps boilerplate (nav, footer, sidebar,
        // cookie banner) out of the embedding stream. Falls back to
        // the legacy body-strip path if the reader pass produces
        // too little (over-aggressive heuristic on minimal pages).
        let reader = readerExtract(from: html)
        let normalised = collapseWhitespace(reader.text)
        let rawSize = reader.text.count
        let path: String
        let finalText: String

        if normalised.count < minExtractedChars {
            let fallbackRaw = extractBody(from: html)
            let fallback = collapseWhitespace(fallbackRaw)
            if fallback.count < minExtractedChars {
                log.error("fetch empty content for \(url.absoluteString, privacy: .public) — reader=\(normalised.count, privacy: .public) fallback=\(fallback.count, privacy: .public) bytes=\(data.count, privacy: .public)")
                throw ExtractionError.emptyContent
            }
            log.notice("fetch: reader pass returned \(normalised.count, privacy: .public) chars (path=\(reader.path, privacy: .public)) — falling back to body-strip (\(fallback.count, privacy: .public) chars)")
            path = "body-fallback"
            finalText = fallback
        } else {
            path = reader.path
            finalText = normalised
        }

        log.info("fetch ok: \(finalURL.absoluteString, privacy: .public) path=\(path, privacy: .public) bytes=\(data.count, privacy: .public) raw=\(rawSize, privacy: .public) chars=\(finalText.count, privacy: .public) title=\(title ?? "(none)", privacy: .public)")
        return Page(
            title: title,
            plainText: finalText,
            finalURL: finalURL,
            fetchedBytes: data.count,
            extractionPath: path
        )
    }

    // MARK: - HTML helpers
    //
    // Implemented as plain string operations rather than a real DOM
    // parser. The trade-off is conscious: pulling SwiftSoup or libxml
    // in for one feature adds risk surface; the regex layer is
    // forgiving of malformed HTML in a way DOM parsers usually
    // aren't, and the worst failure mode is a slightly noisier body
    // — never a crash, never a hang.
    //
    // ## Reader-style pass (`readerExtract`)
    // Implemented as a 4-step pipeline:
    //   1. Strip non-content blocks wholesale (script, style, nav,
    //      header, footer, aside, form, …) before container picking.
    //      Critical: a container that contains a `<nav>` shouldn't
    //      be penalised by the heuristic just because the nav is
    //      character-heavy.
    //   2. Try container heuristics in priority: `<article>` →
    //      `<main>` → `[role="main"]` → text-density picker → whole
    //      `<body>`. Each candidate must yield ≥ `minExtractedChars`
    //      after block rendering; otherwise we drop through.
    //   3. Render the chosen container as a series of block elements
    //      (`<h1>`…`<h6>`, `<p>`, `<li>`) in document order. Headings
    //      get a `# ` prefix, list items get `- ` — preserves enough
    //      structure that retrieval queries can latch onto section
    //      titles without us needing a full Markdown converter.
    //   4. Final whitespace collapse happens in the caller via
    //      `collapseWhitespace`.

    /// Block-element category emitted by the reader pass. Used only
    /// inside this file; the renderer maps each kind to a textual
    /// prefix and joins blocks with `\n\n`.
    private enum BlockKind { case heading; case paragraph; case listItem }

    /// Top-level reader pass. Returns the rendered plain text plus a
    /// label describing which heuristic won — surfaced in logs and
    /// `Page.extractionPath` so debugging can pinpoint why a page
    /// produced noisy output without re-running the pipeline.
    static func readerExtract(from rawHTML: String) -> (text: String, path: String) {
        var working = rawHTML

        // Phase 1: strip non-content blocks wholesale.
        for tag in [
            "script", "style", "noscript", "template", "svg", "iframe",
            "nav", "header", "footer", "aside", "form", "button",
            "fieldset", "dialog", "select", "option", "picture", "source",
            "audio", "video", "canvas", "map", "object", "embed"
        ] {
            working = removeBlock(tag: tag, from: working)
        }

        // Narrow to <body>…</body> if present. Avoids the title /
        // meta / link soup in <head> influencing density rankings.
        if let bodyRange = matchRange(pattern: "<body[^>]*>(.*?)</body>", in: working) {
            working = (working as NSString).substring(with: bodyRange)
        }

        // Phase 2/3: try container candidates in priority order.
        // Each candidate is rendered through `renderBlocks`; the
        // first whose rendered text clears `minExtractedChars` wins.

        if let articleHTML = firstBalancedContent(tagName: "article", in: working) {
            let rendered = renderBlocks(from: articleHTML)
            if rendered.count >= minExtractedChars {
                return (rendered, "article")
            }
        }

        if let mainHTML = firstBalancedContent(tagName: "main", in: working) {
            let rendered = renderBlocks(from: mainHTML)
            if rendered.count >= minExtractedChars {
                return (rendered, "main")
            }
        }

        if let roleMainHTML = firstContentWithRole("main", in: working) {
            let rendered = renderBlocks(from: roleMainHTML)
            if rendered.count >= minExtractedChars {
                return (rendered, "role=main")
            }
        }

        if let densest = densestContainer(in: working) {
            let rendered = renderBlocks(from: densest)
            if rendered.count >= minExtractedChars {
                return (rendered, "densest")
            }
        }

        // Whole-body fallback through the same block renderer. Still
        // better than the legacy strip-all-tags path because we keep
        // headings + list bullets visible to retrieval.
        return (renderBlocks(from: working), "whole-body")
    }

    /// Emits the inner-text of every `<h1>`…`<h6>`, `<p>`, and `<li>`
    /// element inside `containerHTML`, in document order, separated by
    /// blank lines.
    ///
    /// Implementation note: rather than building a real DOM, we run a
    /// per-tag lazy regex and merge matches by start offset. The lazy
    /// regex is happy with malformed nesting (a `<p>` whose `</p>` is
    /// missing simply doesn't match), and merging by offset keeps the
    /// emitted order matching what a reader would scroll through.
    /// Trade-off: nested same-tag elements (e.g. a `<li>` inside a
    /// `<li>`) match the *inner* closing tag — minor information loss
    /// on nested lists in exchange for not depending on a DOM parser.
    static func renderBlocks(from containerHTML: String) -> String {
        let ns = containerHTML as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        struct Hit { let start: Int; let kind: BlockKind; let text: String }
        var hits: [Hit] = []

        // Tag → kind map. Lazy regex per pattern; we accept the
        // duplication cost (one pass per kind) because the patterns
        // need to differ in `kind` anyway.
        let table: [(pattern: String, kind: BlockKind)] = [
            ("<(h[1-6])\\b[^>]*>(.*?)</\\1>", .heading),
            ("<p\\b[^>]*>(.*?)</p>",          .paragraph),
            ("<li\\b[^>]*>(.*?)</li>",        .listItem)
        ]

        for (pattern, kind) in table {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ) else { continue }
            for match in regex.matches(in: containerHTML, range: fullRange) {
                // Headings capture group is 2 (group 1 is the tag
                // name); paragraphs / list items capture group is 1.
                let groupIdx = kind == .heading ? 2 : 1
                guard match.numberOfRanges > groupIdx else { continue }
                let body = ns.substring(with: match.range(at: groupIdx))
                let cleaned = decodeEntities(stripTags(body))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleaned.count >= 2 else { continue }   // drop solitary punctuation
                hits.append(.init(start: match.range.location, kind: kind, text: cleaned))
            }
        }

        guard !hits.isEmpty else { return "" }
        hits.sort { $0.start < $1.start }

        var lines: [String] = []
        for hit in hits {
            switch hit.kind {
            case .heading:   lines.append("# " + hit.text)
            case .listItem:  lines.append("- " + hit.text)
            case .paragraph: lines.append(hit.text)
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// Returns the innerHTML of the first non-nested `<tag>…</tag>`
    /// pair. Handles same-tag nesting via a depth counter — the
    /// outer pair always wins, which is what we want for `<article>`
    /// and `<main>` containers (these are usually unique per page
    /// anyway, but defensive scanning costs nothing).
    static func firstBalancedContent(tagName tag: String, in html: String) -> String? {
        let openPattern = "<\(tag)\\b[^>]*>"
        let closePattern = "</\(tag)\\b\\s*>"
        guard let openRegex = try? NSRegularExpression(pattern: openPattern, options: [.caseInsensitive]),
              let closeRegex = try? NSRegularExpression(pattern: closePattern, options: [.caseInsensitive])
        else { return nil }

        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let opens = openRegex.matches(in: html, range: full).map { ($0.range, true) }
        let closes = closeRegex.matches(in: html, range: full).map { ($0.range, false) }
        // Merge events in document order. Opens beat closes at the
        // same offset (irrelevant in practice — HTML never has both
        // at one location — but spec-correct).
        let events = (opens + closes).sorted {
            if $0.0.location != $1.0.location { return $0.0.location < $1.0.location }
            return $0.1 && !$1.1
        }

        var depth = 0
        var contentStart = -1
        for (range, isOpen) in events {
            if isOpen {
                if depth == 0 { contentStart = range.location + range.length }
                depth += 1
            } else {
                depth -= 1
                if depth <= 0 {
                    guard contentStart >= 0 else { return nil }
                    let len = range.location - contentStart
                    guard len > 0 else { return nil }
                    return ns.substring(with: NSRange(location: contentStart, length: len))
                }
            }
        }
        return nil
    }

    /// Finds the first element whose opening tag carries
    /// `role="<role>"` (single or double quotes) and returns its
    /// inner HTML. Falls back through the same balanced-scan logic
    /// `firstBalancedContent` uses, so nested elements of the same
    /// tag name don't confuse it.
    static func firstContentWithRole(_ role: String, in html: String) -> String? {
        let pattern = "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*\\brole\\s*=\\s*[\"']\(role)[\"'][^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: html, range: full),
              match.numberOfRanges >= 2 else { return nil }
        let tag = ns.substring(with: match.range(at: 1))
        // Restart the balanced scan inside the substring beginning
        // at this open tag — the helper handles same-tag nesting.
        let suffix = ns.substring(with: NSRange(location: match.range.location, length: full.length - match.range.location))
        return firstBalancedContent(tagName: tag, in: suffix)
    }

    /// Scores every top-level `<div>` / `<section>` / `<article>` /
    /// `<main>` by post-strip text length, and returns the inner HTML
    /// of the heaviest one. The four tag names overlap on purpose:
    /// `<article>` / `<main>` are tried first in `readerExtract`, but
    /// pages without an explicit `<article>` sometimes wrap content
    /// in a `<section>` that's larger than every nearby `<div>`. Tag
    /// is not used in the score — only its content length.
    static func densestContainer(in html: String) -> String? {
        var best: (text: String, length: Int)? = nil

        for tag in ["div", "section", "article", "main"] {
            let openPattern = "<\(tag)\\b[^>]*>"
            let closePattern = "</\(tag)\\b\\s*>"
            guard let openRegex = try? NSRegularExpression(pattern: openPattern, options: [.caseInsensitive]),
                  let closeRegex = try? NSRegularExpression(pattern: closePattern, options: [.caseInsensitive])
            else { continue }

            let ns = html as NSString
            let full = NSRange(location: 0, length: ns.length)
            let opens = openRegex.matches(in: html, range: full).map { ($0.range, true) }
            let closes = closeRegex.matches(in: html, range: full).map { ($0.range, false) }
            let events = (opens + closes).sorted {
                if $0.0.location != $1.0.location { return $0.0.location < $1.0.location }
                return $0.1 && !$1.1
            }

            var depth = 0
            var contentStart = -1
            for (range, isOpen) in events {
                if isOpen {
                    if depth == 0 { contentStart = range.location + range.length }
                    depth += 1
                } else {
                    depth -= 1
                    if depth <= 0 {
                        if contentStart >= 0 {
                            let len = range.location - contentStart
                            if len > 0 {
                                let content = ns.substring(with: NSRange(location: contentStart, length: len))
                                let plainLen = stripTags(content).count
                                if best == nil || plainLen > best!.length {
                                    best = (content, plainLen)
                                }
                            }
                        }
                        contentStart = -1
                        depth = 0   // recover from malformed `</close>` without matching open
                    }
                }
            }
        }
        return best?.text
    }

    static func extractTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>(.*?)</title>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return nil }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges >= 2 else { return nil }
        let captured = ns.substring(with: match.range(at: 1))
        let cleaned = decodeEntities(stripTags(captured))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Strips `<script>`/`<style>`/`<noscript>` block contents, then
    /// removes the remaining tags. The block-strip pass is critical:
    /// JavaScript and CSS bodies often contain template strings or
    /// `>`/`<` characters that would otherwise leak text into the
    /// extracted body and pollute the embedding.
    static func extractBody(from html: String) -> String {
        var s = html

        // Strip block elements wholesale (open tag → close tag inclusive).
        for tag in ["script", "style", "noscript", "template", "svg"] {
            s = removeBlock(tag: tag, from: s)
        }

        // Pull <body>…</body> if present — keeps us from running over
        // `<head>` link/meta noise. Fall through to the full string
        // when there's no body tag (very malformed pages).
        if let bodyRange = matchRange(pattern: "<body[^>]*>(.*?)</body>", in: s) {
            s = (s as NSString).substring(with: bodyRange)
        }

        // Convert block boundaries to newlines BEFORE stripping tags —
        // otherwise everything collapses into one wall of text.
        let blockBoundaryPattern = "</?(p|div|br|li|tr|h[1-6]|section|article|header|footer|nav|main|aside|blockquote|figure|pre)[^>]*>"
        if let regex = try? NSRegularExpression(
            pattern: blockBoundaryPattern,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = regex.stringByReplacingMatches(
                in: s,
                range: range,
                withTemplate: "\n"
            )
        }

        s = stripTags(s)
        s = decodeEntities(s)
        return s
    }

    private static func removeBlock(tag: String, from html: String) -> String {
        let pattern = "<\(tag)[^>]*>.*?</\(tag)>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return html }
        let range = NSRange(location: 0, length: (html as NSString).length)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    private static func stripTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else {
            return html
        }
        let range = NSRange(location: 0, length: (html as NSString).length)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    /// Decodes the entity references HTML actually uses in practice.
    /// Generic numeric entities (`&#NNN;`, `&#xHH;`) are decoded too.
    private static func decodeEntities(_ raw: String) -> String {
        var s = raw
        let named: [(String, String)] = [
            ("&amp;",   "&"),
            ("&lt;",    "<"),
            ("&gt;",    ">"),
            ("&quot;",  "\""),
            ("&#39;",   "'"),
            ("&apos;",  "'"),
            ("&nbsp;",  " "),
            ("&hellip;","…"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&laquo;", "«"),
            ("&raquo;", "»"),
            ("&ldquo;", "“"),
            ("&rdquo;", "”"),
            ("&lsquo;", "‘"),
            ("&rsquo;", "’"),
            ("&copy;",  "©"),
            ("&reg;",   "®"),
            ("&trade;", "™")
        ]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v) }

        // Numeric entities. Walk the string once, decoding `&#…;`
        // tokens; ignore anything that doesn't match the shape.
        s = decodeNumericEntities(s)
        // Trailing `&amp;` from chained decoding (rare in practice
        // but cheap to fix once at the end).
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        return s
    }

    private static func decodeNumericEntities(_ raw: String) -> String {
        let pattern = "&#(x?)([0-9a-fA-F]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return raw
        }
        let ns = raw as NSString
        var result = ""
        var cursor = 0
        let length = ns.length
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: length))
        for match in matches {
            let full = match.range
            if cursor < full.location {
                result.append(ns.substring(with: NSRange(location: cursor, length: full.location - cursor)))
            }
            let hexFlag = ns.substring(with: match.range(at: 1))
            let digits = ns.substring(with: match.range(at: 2))
            let radix = hexFlag.isEmpty ? 10 : 16
            if let code = UInt32(digits, radix: radix),
               let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            } else {
                result.append(ns.substring(with: full))
            }
            cursor = full.location + full.length
        }
        if cursor < length {
            result.append(ns.substring(with: NSRange(location: cursor, length: length - cursor)))
        }
        return result
    }

    /// Collapses every run of whitespace (including the explicit
    /// `\n` boundaries we injected above) into either a single space
    /// or a single newline. Preserves paragraph breaks but removes
    /// gigantic gaps left over from stripped tags.
    static func collapseWhitespace(_ raw: String) -> String {
        var s = raw
        // Tabs → space.
        s = s.replacingOccurrences(of: "\t", with: " ")
        // Multiple newlines (>= 2 separated by optional spaces) → \n\n.
        if let r = try? NSRegularExpression(pattern: "(?:[ ]*\n[ ]*){2,}", options: []) {
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = r.stringByReplacingMatches(in: s, range: range, withTemplate: "\n\n")
        }
        // Single \n → space (so paragraphs stay paragraphs).
        if let r = try? NSRegularExpression(pattern: "(?<!\n)\n(?!\n)", options: []) {
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = r.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
        }
        // Multiple spaces → single space.
        if let r = try? NSRegularExpression(pattern: "[ ]{2,}", options: []) {
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = r.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - NS helpers

    private static func matchRange(pattern: String, in haystack: String) -> NSRange? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return nil }
        let range = NSRange(location: 0, length: (haystack as NSString).length)
        guard let match = regex.firstMatch(in: haystack, range: range),
              match.numberOfRanges >= 2 else { return nil }
        return match.range(at: 1)
    }
}
