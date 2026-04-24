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
    let description = "Searches the web for news, weather, prices, or any fact that needs fresh data. Provide a short query like 'weather Prague' or 'EUR CZK rate today'. Returns the top 3–5 results."

    private let engine: any WebSearchEngine

    init(engine: any WebSearchEngine = MockWebSearchEngine()) {
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
