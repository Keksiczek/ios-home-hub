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

    /// Returns up to `limit` structured search hits for `query`. Each hit
    /// has a title, an absolute URL, and a snippet. Engines / agents
    /// should prefer this over the legacy plain-text wrapper.
    static func searchStructured(query: String, limit: Int = 5) async throws -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lite.duckduckgo.com/lite/")
        else { throw SearchError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // DDG Lite returns its no-JS HTML branch when it sees this UA. A
        // generic "curl/8" UA gets a stub page with zero results.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 " +
            "Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
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
        let hits = parseHits(from: html, limit: limit)
        return hits
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
    /// Output structure (stable since 2017):
    ///   <tr><td …><a class='result-link' href='…'>TITLE</a></td></tr>
    ///   <tr><td class='result-snippet'>SNIPPET</td></tr>
    ///   <tr>(metadata)</tr>
    ///
    /// We pair every `result-link` with the next `result-snippet`.
    /// Failures degrade gracefully: a missing snippet still yields a hit
    /// (title + URL), a missing link skips the row entirely.
    static func parseHits(from html: String, limit: Int) -> [Hit] {
        let titles = matches(in: html, pattern: "<a[^>]+class=['\"]result-link['\"][^>]+href=['\"]([^'\"]+)['\"][^>]*>(.*?)</a>")
        let snippets = matches(in: html, pattern: "<td[^>]+class=['\"]result-snippet['\"][^>]*>(.*?)</td>")

        var out: [Hit] = []
        for (i, match) in titles.enumerated() {
            guard match.count >= 3 else { continue }
            let rawURL = match[1]
            let rawTitle = match[2]
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
