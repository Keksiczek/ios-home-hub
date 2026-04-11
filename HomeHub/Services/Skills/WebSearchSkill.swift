import Foundation

struct WebSearchSkill: Skill {
    let name = "WebSearch"
    let description = "Searches DuckDuckGo HTML for news, weather, or real-time facts. Provide a simple query. E.g. 'Weather Prague' or 'Apple latest news'."
    
    func execute(input: String) async throws -> String {
        return try await WebSearchService.search(query: input)
    }
}
