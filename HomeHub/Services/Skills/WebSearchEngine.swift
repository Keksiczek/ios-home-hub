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

/// In-memory stub used by previews, tests, and as a safety fallback when
/// the user hasn't picked a real provider. Returns deterministic
/// canned results so the chat UI can be developed without burning real
/// network round-trips.
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
