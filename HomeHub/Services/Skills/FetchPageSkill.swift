import Foundation

/// Skill that fetches a single URL, strips HTML to readable text, and
/// returns the first ~2 KB so the model can answer with concrete
/// content instead of just snippet summaries.
///
/// Designed to compose with `WebSearchSkill`: the model first searches,
/// picks the best-looking hit, then calls `FetchPage` with that URL.
/// The two-step is what turns "I found 5 results" into "the article
/// says X" — DDG / SearXNG snippets are 100-200 chars at most and
/// usually drop the answer the user actually wants.
///
/// **Design choices**:
/// - Static HTML only — no JavaScript rendering. Roughly 95% of
///   articles, Wikipedia, news, docs render their content without JS.
///   The remaining 5% (SPAs, paywalls) come back with a near-empty
///   body and the model should fall back to citing the snippet.
/// - Aggressive size cap (default 2 KB after stripping) — the token
///   budget on small on-device models is tight and a full article
///   blows the prompt context easily. 2 KB is roughly 500 words /
///   2-3 paragraphs — enough for a fact lookup, small enough to not
///   crowd out conversation history.
/// - Network errors are swallowed and reported as a string the model
///   can act on ("Could not fetch URL: <reason>"). Throwing would
///   abort the agentic loop and the model never gets to recover.
/// - Light HTML→text: strip `<script>` and `<style>` blocks entirely,
///   collapse other tags to whitespace, decode the common HTML
///   entities. Not a full sanitizer — we never render this anywhere,
///   just feed it back to the LLM as plain text. The model sees the
///   words, not the markup.
struct FetchPageSkill: Skill {
    let name = "FetchPage"
    let description = """
        Fetches a single web page and returns its readable text content. \
        Use this AFTER WebSearch when you need the actual article body \
        (not just the snippet) to answer a question — pick the most \
        relevant URL from the search results and call FetchPage with it. \
        Input: the URL only (e.g. `https://example.com/article`). \
        Returns: page title + the first ~500 words of body text. \
        Static HTML only; SPA / JS-rendered pages may come back empty.
        """

    /// Maximum bytes of readable text returned to the model. 2 KB ≈
    /// 500 English words ≈ 600-1000 tokens depending on tokeniser.
    /// Tight on purpose — see file header.
    private let maxBodyBytes: Int

    /// Hard request timeout. Static-HTML reads should always finish in
    /// well under 10 s on a working connection; anything longer is
    /// probably a paywall / interstitial / DDoS check we won't get
    /// past either way.
    private let timeout: TimeInterval

    /// Hard cap on response bytes downloaded before we decide to truncate.
    /// Some sites stream multi-MB pages with the actual article up top;
    /// reading the first 200 KB and dropping the rest is the right
    /// trade for what we ship back to the model.
    private let maxDownloadBytes: Int

    init(
        maxBodyBytes: Int = 2048,
        maxDownloadBytes: Int = 200_000,
        timeout: TimeInterval = 8
    ) {
        self.maxBodyBytes = maxBodyBytes
        self.maxDownloadBytes = maxDownloadBytes
        self.timeout = timeout
    }

    func execute(input: String) async throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.normaliseURL(trimmed) else {
            return "Error: FetchPage needs a full URL (https://...). Got: \"\(trimmed)\"."
        }
        HHLog.tool.info("FetchPage: \(url.absoluteString, privacy: .public)")

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 " +
            "Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let html: String
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return "Could not fetch \(url.absoluteString): HTTP \(http.statusCode)."
            }
            // Cap before decoding so a 50 MB response doesn't get
            // utf8-decoded into a 100 MB String just to be discarded.
            let truncated = data.count > maxDownloadBytes
                ? data.prefix(maxDownloadBytes)
                : data
            html = String(data: truncated, encoding: .utf8)
                ?? String(data: truncated, encoding: .isoLatin1)
                ?? ""
        } catch {
            return "Could not fetch \(url.absoluteString): \(error.localizedDescription)."
        }
        guard !html.isEmpty else {
            return "Could not fetch \(url.absoluteString): empty response body."
        }

        let title = Self.extractTitle(from: html) ?? url.host ?? "(no title)"
        let body = Self.htmlToText(html, byteCap: maxBodyBytes)
        if body.isEmpty {
            return """
                FetchPage \(url.absoluteString):
                Title: \(title)
                (No readable body text — page may be JS-rendered or behind a paywall.)
                """
        }
        return """
            FetchPage \(url.absoluteString):
            Title: \(title)

            \(body)
            """
    }

    // MARK: - URL handling

    /// Accepts `https://example.com/foo`, `http://...`, or a bare
    /// `example.com/foo` and promotes the latter to https. Rejects
    /// schemes other than http/https — file:// and javascript:
    /// shouldn't be reachable from a tool call.
    static func normaliseURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        let candidate: String = {
            if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
                return raw
            }
            return "https://" + raw
        }()
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    // MARK: - HTML → text

    /// Pulls the contents of the first `<title>...</title>` tag.
    /// Decodes a small set of HTML entities so the model sees readable
    /// text instead of `&amp;` runs.
    static func extractTitle(from html: String) -> String? {
        guard let range = html.range(
            of: "<title[^>]*>(.*?)</title>",
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        // Strip the surrounding `<title>` / `</title>` tags then decode.
        let inner = html[range]
            .replacingOccurrences(of: "<title[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</title>", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = decodeEntities(inner)
        return decoded.isEmpty ? nil : decoded
    }

    /// Light HTML → readable text. Order matters:
    ///   1. Drop `<script>` / `<style>` blocks (and their contents).
    ///   2. Replace `<br>` and block-element openings with newlines so
    ///      the output keeps paragraph structure.
    ///   3. Strip every other tag (leaves the text between them).
    ///   4. Decode the common HTML entities.
    ///   5. Collapse runs of whitespace.
    ///   6. Truncate to `byteCap` UTF-8 bytes (cleanly, at a word
    ///      boundary when possible).
    static func htmlToText(_ html: String, byteCap: Int) -> String {
        var work = html

        // Strip script + style blocks entirely.
        work = work.replacingOccurrences(
            of: "<script[\\s\\S]*?</script>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        work = work.replacingOccurrences(
            of: "<style[\\s\\S]*?</style>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        // Block-element openings → newlines so paragraphs survive.
        work = work.replacingOccurrences(
            of: "<(br|p|div|h[1-6]|li|tr|article|section|header|footer)[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        // Drop everything else inside angle brackets. Greedy is fine
        // here because we already stripped the only blocks where the
        // opening / closing tags spanned interesting content.
        work = work.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        work = decodeEntities(work)

        // Collapse whitespace runs but preserve newlines that mark
        // paragraph boundaries.
        work = work.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )
        work = work.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        work = work.trimmingCharacters(in: .whitespacesAndNewlines)

        // Byte-clean truncation. Walk back from the cap to the previous
        // space (or newline) so the model doesn't get a mid-word slice.
        if work.utf8.count > byteCap {
            let prefix = work.utf8.prefix(byteCap)
            if var trimmed = String(prefix) {
                if let lastBreak = trimmed.lastIndex(where: { $0 == " " || $0 == "\n" }) {
                    trimmed = String(trimmed[..<lastBreak])
                }
                work = trimmed + "…"
            }
        }
        return work
    }

    /// Decodes the handful of named / numeric HTML entities that matter
    /// for readable text. Not a full WHATWG implementation — full
    /// `&copy;` etc. survive as literals if they slip through, and
    /// that's fine.
    static func decodeEntities(_ raw: String) -> String {
        var out = raw
        let named: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;",  "&"),
            ("&lt;",   "<"),
            ("&gt;",   ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;",  "'"),
            ("&#x27;", "'"),
            ("&#x2F;", "/"),
            ("&#47;",  "/"),
            ("&hellip;", "…"),
            ("&mdash;",  "—"),
            ("&ndash;",  "–")
        ]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities `&#nnnn;`. Replace by walking matches — Swift's
        // regex API doesn't expose a callback-replace so we collect
        // (range, replacement) pairs in a single pass.
        let pattern = try? NSRegularExpression(pattern: "&#([0-9]+);")
        if let pattern {
            let nsString = out as NSString
            let matches = pattern.matches(in: out, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let codeRange = match.range(at: 1)
                guard let code = Int(nsString.substring(with: codeRange)),
                      let scalar = Unicode.Scalar(code) else { continue }
                out = (out as NSString).replacingCharacters(in: match.range, with: String(scalar))
            }
        }
        return out
    }
}
