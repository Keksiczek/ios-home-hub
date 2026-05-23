import Foundation

/// Single search hit returned by a `WebSearchEngine`.
///
/// Kept deliberately small — title, URL, snippet — so the prompt
/// rendering layer can fit several hits inside a tight token budget.
/// Engines that want to surface richer metadata (favicon, publish
/// date, source) should encode it into `snippet` rather than growing
/// this struct, since the LLM only ever sees the rendered text.
struct SearchResult: Equatable, Codable, Identifiable {
    var id: String { url }   // URL is unique enough for SwiftUI list ids.
    let title: String
    let url: String
    let snippet: String
}

/// Pluggable search backend.
///
/// The agentic loop talks only to this protocol so the actual provider
/// (DuckDuckGo HTML, a SearXNG instance, an offline mock) can be
/// swapped without touching `SkillManager`, `ConversationService`, or
/// the system prompt.
///
/// Conformers MUST:
///   * never throw network errors — return `[]` and log instead, so the
///     LLM gets a clean "no results" observation rather than a wrapped
///     `URLError` it has no way to act on,
///   * keep their result count modest (≤ 5). The model has no way to
///     scroll, and a long result list bleeds context tokens.
protocol WebSearchEngine: Sendable {
    /// Human-readable label used in Settings + the chat tool-result chip
    /// ("🔍 web search via DuckDuckGo"). Kept short.
    var displayName: String { get }

    /// Performs the search. Implementations should silently swallow
    /// transport-level failures and return an empty array.
    func search(query: String) async -> [SearchResult]
}

extension WebSearchEngine {
    /// Renders results as the plain-text observation the LLM splices
    /// into its next turn. Kept here (rather than per-engine) so every
    /// engine produces the same shape — easier to test, easier for the
    /// model to learn.
    func renderObservation(query: String, results: [SearchResult]) -> String {
        guard !results.isEmpty else {
            return "No results for \"\(query)\"."
        }
        var lines: [String] = ["Web results for \"\(query)\" (via \(displayName)):"]
        for (i, hit) in results.prefix(5).enumerated() {
            lines.append("\(i + 1). \(hit.title)")
            if !hit.snippet.isEmpty {
                lines.append("   \(hit.snippet)")
            }
            lines.append("   \(hit.url)")
        }
        return lines.joined(separator: "\n")
    }
}

#if DEBUG
/// In-memory stub used by previews and tests ONLY. Gated behind
/// `#if DEBUG` so the symbol can't accidentally ship in a Release
/// binary — Production now always wires a real engine
/// (`AppContainer.makeWebSearchEngine`) and a stale `MockWebSearchEngine`
/// reference in a release branch would mean "WebSearch quietly returns
/// fake URLs", which is far worse than a compile error.
struct MockWebSearchEngine: WebSearchEngine {
    let displayName = "Mock"

    func search(query: String) async -> [SearchResult] {
        // A handful of obviously-fake results — clearly synthetic so
        // testers don't mistake them for live data.
        [
            SearchResult(
                title: "[Mock] Top result for \(query)",
                url: "https://example.invalid/mock/1",
                snippet: "Synthetic snippet about \(query) — this engine is a stub used in previews."
            ),
            SearchResult(
                title: "[Mock] Secondary result",
                url: "https://example.invalid/mock/2",
                snippet: "Another canned result. Wire a real engine for live data."
            )
        ]
    }
}
#endif

/// Thin adapter around `WebSearchService`'s structured DuckDuckGo Lite
/// scraper. Lives behind the `WebSearchEngine` protocol so the rest of
/// the app doesn't have to know which provider is active.
///
/// The engine never throws — `search(query:)` always returns either real
/// results or `[]`. The agentic loop renders an empty list as
/// "No results for …" so the LLM can answer "I couldn't find that
/// online" cleanly instead of getting a wrapped `URLError` it has no
/// idea what to do with.
struct DuckDuckGoLiteEngine: WebSearchEngine {
    let displayName = "DuckDuckGo"

    /// Maximum hits returned per query. Five is the sweet spot for
    /// small models — enough to triangulate on a fact, not so many that
    /// the snippets blow the context budget.
    private let resultLimit: Int

    init(resultLimit: Int = 5) {
        self.resultLimit = resultLimit
    }

    func search(query: String) async -> [SearchResult] {
        do {
            let hits = try await WebSearchService.searchStructured(query: query, limit: resultLimit)
            return hits.map {
                SearchResult(title: $0.title, url: $0.url, snippet: $0.snippet)
            }
        } catch {
            HHLog.tool.error("DuckDuckGo search failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

/// SearXNG-backed search engine.
///
/// SearXNG is a privacy-respecting metasearch frontend that aggregates
/// results from Google, Bing, DuckDuckGo, and others and exposes them
/// via a stable JSON API. Compared to the DDG Lite scraper:
///
///   * **Stable contract** — REST + JSON instead of regex-parsed HTML.
///     A SearXNG schema change is rare and signalled; a DDG layout
///     change silently returns zero hits until someone files a bug.
///   * **Higher quality** — aggregated multi-engine results outrank
///     DDG Lite's no-JS view for most fact-finding queries.
///   * **Self-hostable** — power users can point at their own instance
///     on `localhost:8080` for fully offline-routed search.
///
/// Trade-offs: SearXNG is not a single canonical URL — the user has to
/// provide one (their own instance or a trusted public one), so it's
/// off by default and selected via `AppSettings.searxngBaseURL`. When
/// no URL is configured, `search(query:)` returns `[]` and the agentic
/// loop transparently falls through to whatever fallback the caller
/// wired up (typically `DuckDuckGoLiteEngine`).
struct SearXNGEngine: WebSearchEngine {
    let displayName = "SearXNG"

    /// Base URL of the SearXNG instance, e.g. `https://searx.example.org`.
    /// `nil` (or empty) disables the engine — `search` short-circuits to
    /// `[]` so the loop can fall back to another provider.
    private let baseURL: URL?
    private let resultLimit: Int
    private let timeout: TimeInterval

    init(baseURL: URL? = nil, resultLimit: Int = 5, timeout: TimeInterval = 8) {
        self.baseURL = baseURL
        self.resultLimit = resultLimit
        self.timeout = timeout
    }

    /// Decodes the subset of SearXNG's `/search?format=json` response we
    /// care about. SearXNG returns dozens of fields per result
    /// (engines, category, score, …) — we only need title/url/content
    /// so the prompt rendering stays small and stable across upgrades.
    private struct Response: Decodable {
        struct Hit: Decodable {
            let title: String?
            let url: String?
            let content: String?
        }
        let results: [Hit]?
    }

    func search(query: String) async -> [SearchResult] {
        guard let base = baseURL,
              !base.absoluteString.isEmpty else {
            HHLog.tool.debug("SearXNG not configured — returning [] (caller should fall back)")
            return []
        }
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            HHLog.tool.error("SearXNG: invalid base URL \(base.absoluteString, privacy: .public)")
            return []
        }
        // Idempotent path normalization — accept both `https://host` and
        // `https://host/search` as the user-pasted base.
        if !comps.path.hasSuffix("/search") {
            comps.path = comps.path.hasSuffix("/")
                ? comps.path + "search"
                : comps.path + "/search"
        }
        comps.queryItems = [
            URLQueryItem(name: "q",       value: query),
            URLQueryItem(name: "format",  value: "json"),
            URLQueryItem(name: "safesearch", value: "1")
        ]
        guard let url = comps.url else { return [] }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // SearXNG instances often reject blank UAs as bot traffic.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                HHLog.tool.error("SearXNG: HTTP \(http.statusCode, privacy: .public) from \(url.absoluteString, privacy: .public)")
                return []
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let hits = (decoded.results ?? []).prefix(resultLimit).compactMap { hit -> SearchResult? in
                guard let title = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty,
                      let urlString = hit.url else { return nil }
                let snippet = hit.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return SearchResult(title: title, url: urlString, snippet: snippet)
            }
            return Array(hits)
        } catch {
            HHLog.tool.error("SearXNG search failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

/// Engine that tries `primary` first and falls through to `fallback`
/// when the primary returns no results. Used to wire a configured
/// `SearXNGEngine` in front of `DuckDuckGoLiteEngine` so users with a
/// SearXNG instance get its quality, while users without one keep
/// working through DDG without configuration.
///
/// The fallback only fires on EMPTY results, not errors — the
/// underlying engines already swallow errors and return `[]`, so an
/// empty result is the only "I couldn't help" signal we have to act on.
struct FallbackWebSearchEngine: WebSearchEngine {
    let primary: any WebSearchEngine
    let fallback: any WebSearchEngine

    /// Returns a clean "Web" label rather than the "Primary → Fallback"
    /// chain. Earlier versions returned `"\(primary) → \(fallback)"`,
    /// which leaked the routing arrow into the model's citation
    /// rendering ("…per the Web (SearXNG → DuckDuckGo) result…").
    /// Small models would then echo the arrow verbatim in their
    /// answers; switching to a stable, neutral label removes the
    /// confusion without losing observability — the per-search log
    /// line in `search(query:)` still names which engine actually fired.
    var displayName: String { "Web" }

    func search(query: String) async -> [SearchResult] {
        let primaryResults = await primary.search(query: query)
        if !primaryResults.isEmpty { return primaryResults }
        HHLog.tool.info("WebSearch primary \(primary.displayName, privacy: .public) empty — trying fallback \(fallback.displayName, privacy: .public)")
        return await fallback.search(query: query)
    }
}
