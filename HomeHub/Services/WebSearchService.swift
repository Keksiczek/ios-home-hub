import Foundation

enum WebSearchService {
    enum SearchError: Error, LocalizedError {
        case invalidURL
        case networkError(Error)
        case parsingError
        
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Nepodařilo se vytvořit vyhledávací odkaz."
            case .networkError(let err): return "Chyba sítě: \(err.localizedDescription)"
            case .parsingError: return "Nepodařilo se analyzovat HTML stránky."
            }
        }
    }
    
    /// Searches DuckDuckGo Lite and returns a plain text summary of the top result snippets.
    static func search(query: String) async throws -> String {
        // Use DDG Lite for a simple HTML structure
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lite.duckduckgo.com/lite/") else {
            throw SearchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = "q=\(encodedQuery)".data(using: .utf8)
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let htmlString = String(data: data, encoding: .utf8) else {
                throw SearchError.parsingError
            }
            
            return parseSnippets(from: htmlString)
        } catch {
            throw SearchError.networkError(error)
        }
    }
    
    /// A very naive regex-based HTML snippet extractor for DuckDuckGo Lite.
    /// In a production scenario, SwiftSoup is highly recommended over Regex for HTML.
    private static func parseSnippets(from html: String) -> String {
        // DDG Lite puts results under class "snippet"
        let pattern = "<td class='result-snippet'[^>]*>(.*?)</td>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return "Výsledky se nepodařilo zpracovat."
        }
        
        let nsString = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsString.length))
        
        var results: [String] = []
        for match in matches.prefix(3) { // Take top 3 results
            let snippetHTML = nsString.substring(with: match.range(at: 1))
            // Strip any remaining inner HTML tags
            let cleanSnippet = snippetHTML.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            results.append("- \(cleanSnippet)")
        }
        
        if results.isEmpty {
            return "Nebyly nalezeny žádné relevantní online výsledky."
        }
        
        return "Online vyhledávání (\(Date())): \n" + results.joined(separator: "\n")
    }
}
