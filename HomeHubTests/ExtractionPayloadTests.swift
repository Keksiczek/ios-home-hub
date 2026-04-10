import XCTest
@testable import HomeHub

final class ExtractionPayloadTests: XCTestCase {

    // MARK: - JSON Decoding

    func testDecodesValidPayloadWithFactsAndEpisodes() throws {
        let json = """
        {
          "facts": [
            {"content": "User works at Apple", "category": "work", "confidence": 0.9},
            {"content": "Prefers dark mode", "category": "preferences", "confidence": 0.8}
          ],
          "episodes": [
            {"summary": "Working on a SwiftUI migration project", "confidence": 0.85}
          ]
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(ExtractionPayload.self, from: json)
        XCTAssertEqual(payload.facts.count, 2)
        XCTAssertEqual(payload.episodes.count, 1)
        XCTAssertEqual(payload.facts[0].content, "User works at Apple")
        XCTAssertEqual(payload.facts[0].category, "work")
        XCTAssertEqual(payload.facts[0].confidence, 0.9)
        XCTAssertEqual(payload.episodes[0].summary, "Working on a SwiftUI migration project")
    }

    func testDecodesEmptyPayload() throws {
        let json = """
        {"facts": [], "episodes": []}
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(ExtractionPayload.self, from: json)
        XCTAssertTrue(payload.isEmpty)
        XCTAssertTrue(payload.facts.isEmpty)
        XCTAssertTrue(payload.episodes.isEmpty)
    }

    func testDecodesPayloadWithMissingConfidence() throws {
        let json = """
        {
          "facts": [{"content": "Lives in NYC", "category": "personal"}],
          "episodes": [{"summary": "Planning a vacation"}]
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(ExtractionPayload.self, from: json)
        XCTAssertNil(payload.facts[0].confidence)
        XCTAssertNil(payload.episodes[0].confidence)
    }

    func testFailsOnInvalidJSON() {
        let badJSON = "this is not json".data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(ExtractionPayload.self, from: badJSON)
        )
    }

    func testFailsOnMissingRequiredFields() {
        let missingFacts = """
        {"episodes": []}
        """.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(ExtractionPayload.self, from: missingFacts)
        )
    }

    // MARK: - Validation / toCandidates

    func testToCandidatesMapsCategoriesCorrectly() throws {
        let payload = ExtractionPayload(
            facts: [
                .init(content: "Works at Apple", category: "work", confidence: 0.9),
                .init(content: "Likes hiking", category: "preferences", confidence: 0.8),
                .init(content: "Unknown category", category: "nonexistent", confidence: 0.7)
            ],
            episodes: []
        )

        let conversationID = UUID()
        let messageID = UUID()
        let candidates = payload.toCandidates(
            sourceConversationID: conversationID,
            sourceMessageID: messageID
        )

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].category, .work)
        XCTAssertEqual(candidates[1].category, .preferences)
        XCTAssertEqual(candidates[2].category, .other) // fallback for unknown
    }

    func testToCandidatesFiltersTooShortContent() {
        let payload = ExtractionPayload(
            facts: [.init(content: "Hi", category: "personal", confidence: 0.9)],
            episodes: [.init(summary: "OK", confidence: 0.9)]
        )
        let candidates = payload.toCandidates(
            sourceConversationID: UUID(), sourceMessageID: UUID()
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testToCandidatesFiltersTooLongContent() {
        let longContent = String(repeating: "a", count: 301)
        let payload = ExtractionPayload(
            facts: [.init(content: longContent, category: "personal", confidence: 0.9)],
            episodes: []
        )
        let candidates = payload.toCandidates(
            sourceConversationID: UUID(), sourceMessageID: UUID()
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testToCandidatesFiltersLowConfidence() {
        let payload = ExtractionPayload(
            facts: [.init(content: "Low confidence fact", category: "work", confidence: 0.2)],
            episodes: [.init(summary: "Low confidence episode", confidence: 0.1)]
        )
        let candidates = payload.toCandidates(
            sourceConversationID: UUID(), sourceMessageID: UUID()
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testToCandidatesPassesNilConfidence() {
        let payload = ExtractionPayload(
            facts: [.init(content: "No confidence given", category: "work", confidence: nil)],
            episodes: []
        )
        let candidates = payload.toCandidates(
            sourceConversationID: UUID(), sourceMessageID: UUID()
        )
        XCTAssertEqual(candidates.count, 1)
    }

    func testToCandidatesSetsCorrectKind() {
        let payload = ExtractionPayload(
            facts: [.init(content: "A durable fact here", category: "personal", confidence: 0.9)],
            episodes: [.init(summary: "An episode summary here", confidence: 0.8)]
        )
        let candidates = payload.toCandidates(
            sourceConversationID: UUID(), sourceMessageID: UUID()
        )
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].kind, .fact)
        XCTAssertEqual(candidates[1].kind, .episode)
    }

    func testToCandidatesPreservesProvenance() {
        let conversationID = UUID()
        let messageID = UUID()
        let payload = ExtractionPayload(
            facts: [.init(content: "Some fact about user", category: "work", confidence: 0.9)],
            episodes: []
        )
        let candidates = payload.toCandidates(
            sourceConversationID: conversationID, sourceMessageID: messageID
        )
        XCTAssertEqual(candidates[0].sourceConversationID, conversationID)
        XCTAssertEqual(candidates[0].sourceMessageID, messageID)
        XCTAssertEqual(candidates[0].extractionMethod, .structured)
    }

    func testToCandidatesTrimsWhitespace() {
        let payload = ExtractionPayload(
            facts: [.init(content: "  Trimmed fact content  ", category: "work", confidence: 0.9)],
            episodes: []
        )
        let candidates = payload.toCandidates(
            sourceConversationID: UUID(), sourceMessageID: UUID()
        )
        XCTAssertEqual(candidates[0].content, "Trimmed fact content")
    }
}
