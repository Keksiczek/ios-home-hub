import Foundation

/// DuckDuckGo Lite scraper used by `DuckDuckGoLiteEngine`.
///
/// This is the only network-touching code path the agentic loop has, so
/// it's deliberately small, dependency-free, and tolerant of HTML drift:
///   * a 6-second URLSession timeout — slow networks shouldn't lock up the
///     chat for 30 seconds while iOS waits for the default URLSession
///     timeout to expire,
///   * a User-Agent header so DDG doesn't return its bot-blocking page,
///   * structured parsing into `(title, url, snippet)` so the chat UI can
///     render clickable result chips and the LLM sees a clean, citable
///     observation,
///   * graceful fallback: parsing failures return an empty list, never
///     throw — `DuckDuckGoLiteEngine` collapses that into a "No results"
///     observation the model can act on.
enum WebSearchService {

    /// Single hit returned by `searchStructured`. Kept tiny on purpose —
    /// the LLM only sees `title`, `url`, `snippet`, so adding fields the
    /// prompt won't display just bloats the context budget.
    struct Hit: Equatable {
        let title: String
        let url: String
        let snippet: String
    }

    enum SearchError: Error, LocalizedError {
        case invalidURL
        case networkError(Error)
        case parsingError
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .invalidURL:        return "Nepodařilo se vytvořit vyhledávací odkaz."
            case .networkError(let err): return "Chyba sítě: \(err.localizedDescription)"
            case .parsingError:      return "Nepodařilo se analyzovat HTML stránky."
            case .rateLimited:       return "DuckDuckGo dočasně omezilo počet dotazů."
            }
        }
    }

    /// Per-request timeout. DDG Lite typically responds in under a second;
    /// anything longer than 6s is almost always a stalled connection that
    /// will eventually fail anyway.
    private static let requestTimeout: TimeInterval = 6.0

    /// In-process response cache. DDG results for the same query don't
    /// meaningfully change minute-to-minute; caching dodges the round
    /// trip when the user re-asks the same question, the agent loops
    /// back over a query it already issued in the same turn, or two
    /// concurrent chats happen to need the same lookup. Capped both by
    /// count and by per-entry TTL so a long session doesn't accrete
    /// stale results indefinitely.
    private static let cacheTTL: TimeInterval = 5 * 60
    private static let cacheCap = 64
    private final class CacheEntry {
        let hits: [Hit]
        let storedAt: Date
        let limit: Int
        init(hits: [Hit], limit: Int) {
            self.hits = hits
            self.storedAt = Date()
            self.limit = limit
        }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, CacheEntry> = {
        let c = NSCache<NSString, CacheEntry>()
        c.countLimit = cacheCap
        return c
    }()

    private static func cacheKey(query: String, limit: Int) -> NSString {
        return "\(limit):\(query.lowercased())" as NSString
    }

    private static func cachedHits(query: String, limit: Int) -> [Hit]? {
        let key = cacheKey(query: query, limit: limit)
        guard let entry = cache.object(forKey: key) else { return nil }
        if Date().timeIntervalSince(entry.storedAt) > cacheTTL {
            cache.removeObject(forKey: key)
            return nil
        }
        return entry.hits
    }

    private static func storeHits(_ hits: [Hit], query: String, limit: Int) {
        cache.setObject(CacheEntry(hits: hits, limit: limit), forKey: cacheKey(query: query, limit: limit))
    }

    /// User-Agent rotation pool. DDG's bot-blocking page is keyed off
    /// (UA + IP + request shape), so on a 429/503 we can sometimes
    /// shake free by switching to a different mobile UA that the
    /// instance has independent rate-limit state for. Listed in
    /// preference order — iPhone Safari is the canonical "this is a
    /// human" signal; iPad Safari and Android Chrome are the fallback
    /// rotations that DDG also reliably hands the no-JS branch.
    private static let userAgentRotation: [String] = [
        // iPhone Safari (default).
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 " +
        "Mobile/15E148 Safari/604.1",
        // iPad Safari — DDG sometimes treats this as a fresh client.
        "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 " +
        "Mobile/15E148 Safari/604.1",
        // Android Chrome — different IP/UA hash bucket entirely.
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36"
    ]

    /// Returns up to `limit` structured search hits for `query`. Each hit
    /// has a title, an absolute URL, and a snippet. Engines / agents
    /// should prefer this over the legacy plain-text wrapper.
    ///
    /// Cached for 5 minutes per `(query, limit)` pair to absorb agentic
    /// retries and rapid user follow-ups. Errors are NOT cached — a
    /// failed lookup retries on the next call.
    ///
    /// On a 429/503 the call retries once with a different User-Agent
    /// from `userAgentRotation` after a short backoff (honouring
    /// `Retry-After` when present, capped at 4 s). This catches the
    /// common case where DDG briefly rate-limits a UA fingerprint —
    /// throwing immediately would have the agentic loop give up on
    /// the search entirely.
    static func searchStructured(query: String, limit: Int = 5) async throws -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lite.duckduckgo.com/lite/")
        else { throw SearchError.invalidURL }

        if let cached = cachedHits(query: trimmed, limit: limit) {
            return cached
        }

        var attempt = 0
        let maxAttempts = 2  // primary + one UA-rotated retry
        var lastError: SearchError = .rateLimited

        while attempt < maxAttempts {
            let ua = userAgentRotation[min(attempt, userAgentRotation.count - 1)]
            do {
                let hits = try await runDDGRequest(
                    encoded: encoded,
                    requestURL: url,
                    userAgent: ua,
                    limit: limit
                )
                // Retry on STRUCTURAL empty too — when DDG silently
                // changes attribute order (the same class of bug the
                // 6ca217d hotfix patched), `parseHits` returns `[]`
                // even though the network round-trip succeeded.
                // Retrying with a different UA sometimes lands on a
                // cached HTML variant that still matches the parser,
                // and it costs us at most one extra ~1 s request.
                if hits.isEmpty && attempt + 1 < maxAttempts {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                if !hits.isEmpty {
                    storeHits(hits, query: trimmed, limit: limit)
                }
                return hits
            } catch SearchError.rateLimited {
                lastError = .rateLimited
                attempt += 1
                guard attempt < maxAttempts else { throw SearchError.rateLimited }
                // Brief backoff before retry. The actual Retry-After
                // value rarely matters — DDG's rate limiter clears
                // within a couple of seconds for an unrelated UA — so
                // we just give the network stack a beat and switch UAs.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            } catch SearchError.parsingError {
                // DDG returned non-2xx (and not 429/503) OR the body
                // wasn't UTF-8. Same retry shape as rate-limit: one
                // chance with a different UA. Common cause is a
                // transient 502/504 from a regional CDN edge that
                // the next UA's hash bucket bypasses.
                lastError = .parsingError
                attempt += 1
                guard attempt < maxAttempts else { throw SearchError.parsingError }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
        }
        // Unreachable — the loop above either returns or throws. The
        // explicit throw uses the last-observed error so a future
        // change that lets the loop fall through here surfaces an
        // accurate cause rather than a hard-coded `rateLimited`.
        throw lastError
    }

    /// Single-attempt DDG Lite fetch. Extracted so the retry path in
    /// `searchStructured` can rotate user agents without duplicating
    /// the request construction.
    private static func runDDGRequest(
        encoded: String,
        requestURL: URL,
        userAgent: String,
        limit: Int
    ) async throws -> [Hit] {
        var request = URLRequest(url: requestURL, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.httpBody = "q=\(encoded)".data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SearchError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 429, 503:  throw SearchError.rateLimited
            default:        throw SearchError.parsingError
            }
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.parsingError
        }
        return parseHits(from: html, limit: limit)
    }

    /// Backwards-compatible plain-text wrapper for callers that haven't
    /// migrated to `searchStructured`. New code should use the structured
    /// API; the model gets nicer output that way.
    static func search(query: String) async throws -> String {
        let hits = (try? await searchStructured(query: query, limit: 3)) ?? []
        guard !hits.isEmpty else { return "Nebyly nalezeny žádné relevantní online výsledky." }
        let lines = hits.map { hit -> String in
            if !hit.url.isEmpty {
                return "- \(hit.title) — \(hit.snippet) (\(hit.url))"
            } else {
                return "- \(hit.title): \(hit.snippet)"
            }
        }
        return "Online vyhledávání:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Parser

    /// Parses DDG Lite's no-JS HTML response.
    ///
    /// Output structure:
    ///   <tr><td …><a rel='nofollow' href='…' class='result-link'>TITLE</a></td></tr>
    ///   <tr><td class='result-snippet'>SNIPPET</td></tr>
    ///   <tr>(metadata)</tr>
    ///
    /// We pair every `result-link` with the next `result-snippet`.
    /// Failures degrade gracefully: a missing snippet still yields a hit
    /// (title + URL), a missing link skips the row entirely.
    ///
    /// NOTE: DDG emits the anchor attributes in `href … class` order
    /// (not `class … href`), and the old single-pass pattern that
    /// required `class` *before* `href` silently matched zero results —
    /// every web search returned "no results". We now match the whole
    /// `result-link` anchor regardless of attribute order and pull
    /// `href` out of the captured attribute blob in a second pass.
    static func parseHits(from html: String, limit: Int) -> [Hit] {
        let anchors = matches(in: html, pattern: "<a\\b([^>]*\\bclass=['\"]result-link['\"][^>]*)>(.*?)</a>")
        let snippets = matches(in: html, pattern: "<td[^>]+class=['\"]result-snippet['\"][^>]*>(.*?)</td>")

        var out: [Hit] = []
        for (i, match) in anchors.enumerated() {
            guard match.count >= 3 else { continue }
            let attrs = match[1]
            let rawTitle = match[2]
            let rawURL = firstCapture(in: attrs, pattern: "href=['\"]([^'\"]+)['\"]") ?? ""
            let snippet = i < snippets.count && snippets[i].count >= 2 ? snippets[i][1] : ""
            let resolvedURL = resolveDDGRedirect(rawURL)
            let cleanTitle = stripHTML(rawTitle)
            let cleanSnippet = stripHTML(snippet)
            guard !cleanTitle.isEmpty else { continue }
            out.append(Hit(title: cleanTitle, url: resolvedURL, snippet: cleanSnippet))
            if out.count >= limit { break }
        }
        return out
    }

    /// First capture group of `pattern` in `haystack`, or `nil` if no
    /// match. Used to pull a single attribute (e.g. `href`) out of an
    /// already-matched tag without caring where it sits in the tag.
    private static func firstCapture(in haystack: String, pattern: String) -> String? {
        guard let first = matches(in: haystack, pattern: pattern).first,
              first.count >= 2 else { return nil }
        return first[1]
    }

    /// DDG Lite wraps every result URL in a `/l/?uddg=<encoded>` redirect.
    /// We unwrap it so the chat UI can show the real domain (and so the
    /// LLM cites a recognizable source instead of `duckduckgo.com/l/?...`).
    private static func resolveDDGRedirect(_ raw: String) -> String {
        guard raw.contains("/l/?") || raw.hasPrefix("//duckduckgo.com/l/") else {
            return raw.hasPrefix("//") ? "https:" + raw : raw
        }
        let normalised = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let comps = URLComponents(string: normalised),
              let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value,
              let decoded = target.removingPercentEncoding else {
            return normalised
        }
        return decoded
    }

    /// Strips inner HTML tags and decodes the half-dozen entities DDG
    /// actually emits. SwiftSoup would be sturdier but pulling in a parser
    /// dependency for this one job isn't worth it.
    private static func stripHTML(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;",  with: "&")
        s = s.replacingOccurrences(of: "&lt;",   with: "<")
        s = s.replacingOccurrences(of: "&gt;",   with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;",  with: "'")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns each match's capture groups as a `[String]` (group 0 first).
    /// Empty list on regex compile failure.
    private static func matches(in haystack: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }
        let ns = haystack as NSString
        let matches = regex.matches(in: haystack, range: NSRange(location: 0, length: ns.length))
        return matches.map { match in
            (0..<match.numberOfRanges).map { idx -> String in
                let r = match.range(at: idx)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
}
