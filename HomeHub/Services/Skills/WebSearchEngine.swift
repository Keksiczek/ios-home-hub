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

/// Thin adapter around the existing `WebSearchService` (DuckDuckGo Lite
/// HTML scraper). Lives behind the `WebSearchEngine` protocol so the
/// rest of the app doesn't have to know which provider is active.
struct DuckDuckGoLiteEngine: WebSearchEngine {
    let displayName = "DuckDuckGo"

    func search(query: String) async -> [SearchResult] {
        do {
            let summary = try await WebSearchService.search(query: query)
            // The legacy service returns a pre-formatted string blob.
            // Parse the bullet lines back into structured results so
            // the chat UI can render them as chips. If parsing fails,
            // wrap the whole blob into a single synthetic result so the
            // LLM still sees the data.
            let parsed = Self.parse(summary: summary)
            if parsed.isEmpty {
                return [SearchResult(title: "DuckDuckGo result", url: "", snippet: summary)]
            }
            return parsed
        } catch {
            HHLog.tool.error("DuckDuckGo search failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Splits the legacy `"- snippet"` lines back into `SearchResult`s.
    /// The DDG Lite scraper doesn't emit per-hit URLs today, so the URL
    /// field is left blank. When the scraper is upgraded to capture
    /// per-result anchors, populate `url` and the chat chips will pick
    /// it up automatically.
    private static func parse(summary: String) -> [SearchResult] {
        summary
            .split(separator: "\n")
            .compactMap { line -> SearchResult? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { return nil }
                let snippet = String(trimmed.dropFirst(2))
                guard !snippet.isEmpty else { return nil }
                return SearchResult(title: snippet, url: "", snippet: "")
            }
    }
}
