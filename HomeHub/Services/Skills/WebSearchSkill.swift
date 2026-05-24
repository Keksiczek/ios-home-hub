import Foundation

/// Native skill exposing a `WebSearchEngine` to the agentic loop.
///
/// The skill itself is a thin wrapper — all provider-specific behaviour
/// lives behind the `WebSearchEngine` protocol so swapping DuckDuckGo
/// for a self-hosted SearXNG (or the `MockWebSearchEngine` in previews)
/// is a one-line change at registration time:
///
/// ```swift
/// await SkillManager.shared.register(WebSearchSkill(engine: DuckDuckGoLiteEngine()))
/// ```
struct WebSearchSkill: Skill {
    let name = "WebSearch"
    let description = """
        Searches the web for news, weather, prices, or any fact that needs fresh data. \
        ALWAYS reformulate the user's question into a short keyword query — do not pass \
        the question verbatim. Examples:
          • User: "co je nového u Apple?" → query: "Apple news 2026"
          • User: "kolik stoji EUR v CZK?" → query: "EUR CZK exchange rate today"
          • User: "jaké je počasí v Praze?" → query: "weather Prague today"
          • User: "kdo vyhrál Ligu mistrů?" → query: "Champions League winner 2025"
        Keep queries to 2-6 keywords; drop filler words. Returns the top 3-5 results \
        as title + snippet + URL. After getting results, you SHOULD call FetchPage on \
        the most relevant URL when the snippet alone doesn't answer the question.
        """

    private let engine: any WebSearchEngine

    init(engine: any WebSearchEngine = DuckDuckGoLiteEngine()) {
        self.engine = engine
    }

    func execute(input: String) async throws -> String {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Error: empty search query."
        }
        HHLog.tool.info("WebSearch via \(engine.displayName, privacy: .public): \(query, privacy: .public)")
        let results = await engine.search(query: query)
        return engine.renderObservation(query: query, results: results)
    }
}
