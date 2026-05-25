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
/// Errors returned by `FetchPageSkill.execute` as the model-visible
/// result string. Sentinel-style — the model never sees the raw error,
/// just the rendered "Could not fetch …" message.
private enum FetchPageError {
    static func blockedHost(_ host: String) -> String {
        "Refused to fetch \(host): private / loopback / metadata addresses are not allowed."
    }
}

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
        if let host = url.host, Self.isBlockedHost(host) {
            // SSRF guard. The model can be prompt-injected via search
            // result content to call FetchPage on a private IP; this
            // refuses outright before the network call. A 192.168.x.x
            // router admin page or AWS metadata IP gets the same
            // structured refusal as `file://` would.
            HHLog.tool.warning("FetchPage refused (blocked host): \(host, privacy: .public)")
            return FetchPageError.blockedHost(host)
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

        // Use a session with a redirect-guarding delegate so a public
        // URL can't 302-bounce us into a private subnet. Sharing
        // `URLSession.shared` doesn't expose the delegate hook for
        // redirects, and a one-shot session with the right delegate
        // is the lightest fix — the session lifetime is one fetch.
        let session = URLSession(
            configuration: .ephemeral,
            delegate: RedirectGuardDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let html: String
        do {
            let (data, response) = try await session.data(for: request)
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
        // Two-source body: an editorial summary (og:description /
        // twitter:description / <meta name=description>) when the page
        // provides one, plus the tag-stripped body text. The meta
        // description is usually a curated 200-300 char abstract — far
        // better signal than the first 2 KB of stripped body, which
        // often contains nav menus, cookie banners, and headers
        // before the article actually starts. We surface BOTH so the
        // model gets the curated summary and the article opening,
        // each labelled, within the same byte budget.
        let metaDescription = Self.extractMetaDescription(from: html)
        let ogImage = Self.extractOGImage(from: html, base: url)
        let body = Self.htmlToText(html, byteCap: maxBodyBytes)
        if body.isEmpty && (metaDescription?.isEmpty ?? true) {
            return """
                FetchPage \(url.absoluteString):
                Title: \(title)
                (No readable body text — page may be JS-rendered or behind a paywall.)
                """
        }
        // Render order: title, then image (if any), then summary (if any),
        // then body. The summary leads because it's typically the more
        // concentrated signal — a model that bails after the first
        // paragraph will still have the curated abstract. The image line
        // is purely for the UI layer (ToolResultChip renders a thumbnail);
        // the LLM ignores it because there's no token-budget reason to
        // burn context on a URL it can't see.
        var lines: [String] = [
            "FetchPage \(url.absoluteString):",
            "Title: \(title)"
        ]
        if let image = ogImage {
            lines.append("Image: \(image.absoluteString)")
        }
        if let summary = metaDescription, !summary.isEmpty {
            lines.append("Summary: \(summary)")
        }
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - URL handling

    // MARK: - SSRF guard

    /// Exact hostnames and host-string prefixes that map to private,
    /// loopback, link-local, or cloud-metadata addresses. Used by
    /// `isBlockedHost` to refuse the fetch before the network call
    /// and (via `RedirectGuardDelegate`) to refuse a 30x bounce into
    /// the same address space.
    ///
    /// Coverage:
    /// - **Loopback**: `127.0.0.0/8`, `::1`, `0.0.0.0`.
    /// - **RFC1918 private**: `10.0.0.0/8`, `192.168.0.0/16`,
    ///   `172.16.0.0/12`.
    /// - **Link-local**: `169.254.0.0/16` (IPv4), `fe80::/10` (IPv6).
    /// - **Unique-local IPv6**: `fc00::/7`.
    /// - **Cloud metadata**: `169.254.169.254` (AWS/GCP/Azure all use
    ///   this), `metadata.google.internal` (GCP hostname).
    /// - **Hostnames**: `localhost` and a couple of trivial aliases.
    ///
    /// Prefix matching is intentional — we don't parse the dotted-quad
    /// because:
    ///   (a) For the host string the model emits, the prefix check
    ///       catches the realistic attack vectors with zero parser
    ///       complexity.
    ///   (b) An attacker who wants to evade this can encode the IP
    ///       as a hex/octal literal (`0x7f000001` for 127.0.0.1) —
    ///       but iOS's `URL` parser rejects most of those before we
    ///       see the host string, and the ones that survive (decimal
    ///       integer form for IPv4) are exotic enough that we accept
    ///       the residual risk in exchange for the simpler code.
    private static let blockedExactHosts: Set<String> = [
        "localhost",
        "ip6-localhost",
        "ip6-loopback",
        "0.0.0.0",
        "127.0.0.1",
        "::1",
        "[::1]",
        "169.254.169.254",
        "metadata.google.internal",
        "metadata"
    ]
    private static let blockedHostPrefixes: [String] = [
        "127.",
        "10.",
        "192.168.",
        "169.254.",
        // RFC1918 172.16.0.0/12 — sixteen second-octet values.
        "172.16.", "172.17.", "172.18.", "172.19.",
        "172.20.", "172.21.", "172.22.", "172.23.",
        "172.24.", "172.25.", "172.26.", "172.27.",
        "172.28.", "172.29.", "172.30.", "172.31.",
        // IPv6 loopback / link-local / unique-local. URL host strings
        // strip the surrounding `[ ]` so we match on the bare prefix.
        "fe80:", "fe80::",
        "fc00:", "fd"
    ]

    /// Decides whether a host should be refused. Lowercases the input
    /// once at the top so an `LOCALHOST` or `127.0.0.1` (canonicalised
    /// either way) hits the same matcher.
    static func isBlockedHost(_ host: String) -> Bool {
        let lc = host.lowercased()
        if blockedExactHosts.contains(lc) { return true }
        return blockedHostPrefixes.contains(where: { lc.hasPrefix($0) })
    }

    // MARK: - URL handling

    /// Accepts `https://example.com/foo`, `http://...`, or a bare
    /// `example.com/foo` and promotes the latter to https. Rejects
    /// schemes other than http/https — file:// and javascript:
    /// shouldn't be reachable from a tool call.
    static func normaliseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        // Reject explicit non-http(s) scheme declarations *before* the
        // bare-host promotion runs. Without this, a value like
        // "file:///etc/passwd" gets silently wrapped to
        // "https://file:///etc/passwd" — parses as host=`file`, path
        // =`/etc/passwd`, sails through scheme validation, and turns
        // into an SSRF / data-exfiltration vector.
        let dangerousSchemes = [
            "file:", "javascript:", "data:", "vbscript:",
            "ftp:", "ftps:", "ws:", "wss:", "ssh:",
            "telnet:", "gopher:", "ldap:", "ldaps:"
        ]
        for scheme in dangerousSchemes where lower.hasPrefix(scheme) {
            return nil
        }

        let candidate: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            candidate = trimmed
        } else {
            candidate = "https://" + trimmed
        }
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

    /// Pulls a short editorial summary from the page's `<meta>` tags.
    /// Tries Open Graph, then Twitter Card, then the generic
    /// `<meta name="description">` — the first non-empty match wins.
    /// Returns `nil` when none of the three exist.
    ///
    /// **Why all three?** Different publishers prefer different
    /// metas:
    ///   * News sites + most CMSes set `og:description` (Facebook /
    ///     LinkedIn share preview drove its adoption).
    ///   * Twitter / older blogs set `twitter:description`.
    ///   * Wikipedia, docs, smaller sites set only the generic
    ///     `description`.
    /// One regex per source keeps the parser predictable — a generic
    /// `<meta[^>]+description[^>]*>` would also match arbitrary
    /// custom metas the user doesn't want surfaced.
    ///
    /// Both `name=` and `property=` attribute orderings are accepted
    /// because the spec allows either; real-world pages do both.
    static func extractMetaDescription(from html: String) -> String? {
        // Patterns ordered by preference; first non-empty wins. Each
        // pattern captures the content via two groups:
        //   group 1: the opening quote character (`"` or `'`)
        //   group 2: the content, terminated by a back-referenced match
        //            to group 1 (`\1`).
        // Using a backreference is what lets the value contain the
        // opposite quote (e.g. `content="Tom &amp; Jerry's adventure"`)
        // without the regex bailing at the apostrophe. The previous
        // `[^"']+` form was off-by-quote and dropped the suffix after
        // the first `'` it saw inside a double-quoted attribute.
        let patterns: [String] = [
            // og:description, attribute order either way
            "<meta[^>]+property\\s*=\\s*[\"']og:description[\"'][^>]+content\\s*=\\s*([\"'])([\\s\\S]*?)\\1",
            "<meta[^>]+content\\s*=\\s*([\"'])([\\s\\S]*?)\\1[^>]+property\\s*=\\s*[\"']og:description[\"']",
            // twitter:description
            "<meta[^>]+name\\s*=\\s*[\"']twitter:description[\"'][^>]+content\\s*=\\s*([\"'])([\\s\\S]*?)\\1",
            "<meta[^>]+content\\s*=\\s*([\"'])([\\s\\S]*?)\\1[^>]+name\\s*=\\s*[\"']twitter:description[\"']",
            // Generic description
            "<meta[^>]+name\\s*=\\s*[\"']description[\"'][^>]+content\\s*=\\s*([\"'])([\\s\\S]*?)\\1",
            "<meta[^>]+content\\s*=\\s*([\"'])([\\s\\S]*?)\\1[^>]+name\\s*=\\s*[\"']description[\"']"
        ]
        let ns = html as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            let match = regex.firstMatch(
                in: html,
                range: NSRange(location: 0, length: ns.length)
            )
            if let match, match.numberOfRanges >= 3 {
                let raw = ns.substring(with: match.range(at: 2))
                let decoded = decodeEntities(raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty { return decoded }
            }
        }
        return nil
    }

    /// Pulls a hero image URL from the page's `<meta>` tags. Tries Open
    /// Graph (`og:image`), Twitter Card (`twitter:image` and the older
    /// `twitter:image:src`), in that order — first non-empty wins.
    ///
    /// Resolves relative URLs against `base` so `og:image` values like
    /// `/static/hero.jpg` or `//cdn.example.com/img.jpg` produce
    /// usable absolute URLs. Returns `nil` when no meta is present or
    /// the value doesn't parse as a URL after resolution.
    ///
    /// **Why this is shipped through the FetchPage output**: the LLM
    /// never sees the image (no vision on small on-device models), but
    /// the chat UI's `ToolResultChip` renders an `AsyncImage` thumbnail
    /// to give the user a visual cue of what was fetched. The line is
    /// emitted with a stable `Image: <url>` prefix so the chip's
    /// observation parser can extract it without re-running the fetch.
    static func extractOGImage(from html: String, base: URL) -> URL? {
        let patterns: [String] = [
            "<meta[^>]+property\\s*=\\s*[\"']og:image[\"'][^>]+content\\s*=\\s*[\"']([^\"']+)[\"']",
            "<meta[^>]+content\\s*=\\s*[\"']([^\"']+)[\"'][^>]+property\\s*=\\s*[\"']og:image[\"']",
            "<meta[^>]+name\\s*=\\s*[\"']twitter:image[\"'][^>]+content\\s*=\\s*[\"']([^\"']+)[\"']",
            "<meta[^>]+content\\s*=\\s*[\"']([^\"']+)[\"'][^>]+name\\s*=\\s*[\"']twitter:image[\"']",
            "<meta[^>]+name\\s*=\\s*[\"']twitter:image:src[\"'][^>]+content\\s*=\\s*[\"']([^\"']+)[\"']",
            "<meta[^>]+content\\s*=\\s*[\"']([^\"']+)[\"'][^>]+name\\s*=\\s*[\"']twitter:image:src[\"']"
        ]
        let ns = html as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            guard let match = regex.firstMatch(
                in: html,
                range: NSRange(location: 0, length: ns.length)
            ), match.numberOfRanges >= 2 else { continue }
            let raw = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty,
                  let resolved = resolveImageURL(raw, base: base),
                  let scheme = resolved.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { continue }
            return resolved
        }
        return nil
    }

    /// Resolves an `og:image` content value against the page URL.
    /// Handles three shapes commonly seen in real pages:
    ///   * Absolute: `https://cdn.example/img.jpg` → use as-is.
    ///   * Protocol-relative: `//cdn.example/img.jpg` → prepend the
    ///     page's scheme.
    ///   * Path-relative: `/static/hero.jpg` or `hero.jpg` → resolve
    ///     against `base`.
    /// `data:` URIs are rejected (no scheme prefix the chip can fetch).
    private static func resolveImageURL(_ raw: String, base: URL) -> URL? {
        if raw.hasPrefix("//") {
            let scheme = base.scheme ?? "https"
            return URL(string: "\(scheme):\(raw)")
        }
        if let direct = URL(string: raw), direct.scheme != nil {
            return direct
        }
        return URL(string: raw, relativeTo: base)?.absoluteURL
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
        // Append " …" with a leading space so the ellipsis is visibly
        // separated from the trailing word — readers (and the
        // `testHtmlToTextTruncatesAtByteCapOnWordBoundary` test) treat
        // `lorem…` as a mid-word slice; `lorem …` makes the truncation
        // explicit and unambiguous.
        if work.utf8.count > byteCap {
            let prefix = work.utf8.prefix(byteCap)
            if var trimmed = String(prefix) {
                if let lastBreak = trimmed.lastIndex(where: { $0 == " " || $0 == "\n" }) {
                    trimmed = String(trimmed[..<lastBreak])
                }
                work = trimmed + " …"
            }
        }
        return work
    }

    /// Re-checks a redirect target against the SSRF blocklist. Without
    /// this, an attacker-controlled public URL could 302-bounce us
    /// into `http://192.168.1.1/...` or `http://169.254.169.254/...`
    /// and `URLSession.shared` would happily follow because the
    /// initial host passed the pre-flight.
    ///
    /// Returning `nil` from the completion handler cancels the
    /// redirect — the original task then fails with `NSURLErrorCancelled`
    /// which `execute` catches and renders as a generic
    /// "Could not fetch …" string. We don't try to differentiate
    /// "cancelled because redirect blocked" vs "user cancelled" in the
    /// model-visible output because the model has no recovery
    /// strategy for either; the unified failure surface is fine.
    private final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let url = request.url, let host = url.host else {
                completionHandler(nil)
                return
            }
            if FetchPageSkill.isBlockedHost(host) {
                HHLog.tool.warning("FetchPage redirect blocked: → \(host, privacy: .public)")
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
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
