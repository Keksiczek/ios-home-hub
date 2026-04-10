import XCTest
@testable import HomeHub

final class MemoryPersistenceTests: XCTestCase {

    // MARK: - MemoryFact backward compatibility

    func testDecodesV1FactWithoutProvenanceFields() throws {
        // v1 persisted JSON has no provenance fields
        let v1JSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "content": "Prefers concise replies",
          "category": "preferences",
          "source": "userManual",
          "confidence": 0.95,
          "createdAt": "2025-01-15T10:00:00Z",
          "pinned": true,
          "disabled": false
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fact = try decoder.decode(MemoryFact.self, from: v1JSON)

        XCTAssertEqual(fact.content, "Prefers concise replies")
        XCTAssertEqual(fact.category, .preferences)
        XCTAssertEqual(fact.source, .userManual)
        XCTAssertTrue(fact.pinned)
        // v2 provenance fields default to nil
        XCTAssertNil(fact.sourceConversationID)
        XCTAssertNil(fact.sourceMessageID)
        XCTAssertNil(fact.extractionMethod)
    }

    func testDecodesV2FactWithProvenanceFields() throws {
        let v2JSON = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "content": "Works at Apple",
          "category": "work",
          "source": "conversationExtraction",
          "confidence": 0.7,
          "createdAt": "2025-03-01T12:00:00Z",
          "pinned": false,
          "disabled": false,
          "sourceConversationID": "33333333-3333-3333-3333-333333333333",
          "sourceMessageID": "44444444-4444-4444-4444-444444444444",
          "extractionMethod": "structured"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fact = try decoder.decode(MemoryFact.self, from: v2JSON)

        XCTAssertEqual(fact.content, "Works at Apple")
        XCTAssertEqual(fact.sourceConversationID,
                       UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(fact.sourceMessageID,
                       UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        XCTAssertEqual(fact.extractionMethod, .structured)
    }

    func testV1FactArrayDecodesWithMixedVersions() throws {
        let mixedJSON = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "content": "Old fact without provenance",
            "category": "personal",
            "source": "onboarding",
            "confidence": 1.0,
            "createdAt": "2025-01-01T00:00:00Z",
            "pinned": false,
            "disabled": false
          },
          {
            "id": "22222222-2222-2222-2222-222222222222",
            "content": "New fact with provenance",
            "category": "work",
            "source": "conversationExtraction",
            "confidence": 0.8,
            "createdAt": "2025-03-01T00:00:00Z",
            "pinned": false,
            "disabled": false,
            "sourceConversationID": "33333333-3333-3333-3333-333333333333",
            "sourceMessageID": "44444444-4444-4444-4444-444444444444",
            "extractionMethod": "heuristic"
          }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let facts = try decoder.decode([MemoryFact].self, from: mixedJSON)

        XCTAssertEqual(facts.count, 2)
        XCTAssertNil(facts[0].extractionMethod)
        XCTAssertEqual(facts[1].extractionMethod, .heuristic)
    }

    // MARK: - MemoryEpisode persistence

    func testEpisodeRoundTrips() throws {
        let episode = MemoryEpisode(
            id: UUID(),
            summary: "Working on SwiftUI migration",
            sourceConversationID: UUID(),
            sourceMessageID: UUID(),
            createdAt: .now,
            lastRelevantAt: nil,
            approved: true,
            disabled: false,
            extractionMethod: .structured
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(episode)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MemoryEpisode.self, from: data)

        XCTAssertEqual(decoded.id, episode.id)
        XCTAssertEqual(decoded.summary, episode.summary)
        XCTAssertEqual(decoded.sourceConversationID, episode.sourceConversationID)
        XCTAssertEqual(decoded.sourceMessageID, episode.sourceMessageID)
        XCTAssertEqual(decoded.approved, true)
        XCTAssertEqual(decoded.extractionMethod, .structured)
    }

    // MARK: - InMemoryStore episode operations

    func testInMemoryStoreEpisodeCRUD() async throws {
        let store = InMemoryStore.empty()

        // Initially empty
        let initial = try await store.loadMemoryEpisodes()
        XCTAssertTrue(initial.isEmpty)

        // Save
        let episode = MemoryEpisode(
            id: UUID(),
            summary: "Planning a trip to Japan",
            sourceConversationID: UUID(),
            sourceMessageID: UUID(),
            createdAt: .now,
            lastRelevantAt: nil,
            approved: true,
            disabled: false,
            extractionMethod: .structured
        )
        try await store.save(episode: episode)
        let afterSave = try await store.loadMemoryEpisodes()
        XCTAssertEqual(afterSave.count, 1)
        XCTAssertEqual(afterSave[0].summary, "Planning a trip to Japan")

        // Update
        var updated = episode
        updated.disabled = true
        try await store.save(episode: updated)
        let afterUpdate = try await store.loadMemoryEpisodes()
        XCTAssertEqual(afterUpdate.count, 1)
        XCTAssertTrue(afterUpdate[0].disabled)

        // Delete
        try await store.deleteMemoryEpisode(id: episode.id)
        let afterDelete = try await store.loadMemoryEpisodes()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    // MARK: - ExtractionMethod codable

    func testExtractionMethodCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let heuristicData = try encoder.encode(ExtractionMethod.heuristic)
        let decoded = try decoder.decode(ExtractionMethod.self, from: heuristicData)
        XCTAssertEqual(decoded, .heuristic)

        let structuredData = try encoder.encode(ExtractionMethod.structured)
        let decoded2 = try decoder.decode(ExtractionMethod.self, from: structuredData)
        XCTAssertEqual(decoded2, .structured)
    }
}
