import XCTest
@testable import HomeHub

/// Stub runtime that returns a specific JSON response for extraction.
private final class ExtractionStubRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "extraction-stub"
    var loadedModel: LocalModel?
    var responseText: String = ""

    func load(model: LocalModel) async throws { loadedModel = model }
    func unload() async { loadedModel = nil }

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        let text = responseText
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(text))
            continuation.yield(.finished(
                reason: .stop,
                stats: RuntimeStats(tokensGenerated: 1, tokensPerSecond: 100, totalDurationMs: 10)
            ))
            continuation.finish()
        }
    }
}

private let stubModel = LocalModel(
    id: "test-model", displayName: "Test", family: "test",
    parameterCount: "1B", quantization: "q4", sizeBytes: 1_000_000,
    contextLength: 2048,
    downloadURL: URL(string: "https://example.com/model.gguf")!,
    sha256: nil,
    installState: .installed(localURL: URL(fileURLWithPath: "/tmp/test.gguf")),
    recommendedFor: [.iPhone], license: "MIT"
)

@MainActor
final class MemoryServiceTests: XCTestCase {

    /// Creates a service with heuristic-only extraction (no runtime).
    private func makeHeuristicService() -> (MemoryService, InMemoryStore) {
        let store = InMemoryStore.empty()
        let settings = SettingsService(store: store)
        let extractor = MemoryExtractionService(runtime: nil)
        let service = MemoryService(store: store, settings: settings, extractor: extractor)
        return (service, store)
    }

    /// Creates a service with a stub runtime for structured extraction.
    private func makeStructuredService(
        responseJSON: String
    ) async -> (MemoryService, InMemoryStore) {
        let store = InMemoryStore.empty()
        let settings = SettingsService(store: store)
        let runtime = ExtractionStubRuntime()
        await runtime.load(model: stubModel)
        runtime.responseText = responseJSON
        let extractor = MemoryExtractionService(runtime: runtime)
        let service = MemoryService(store: store, settings: settings, extractor: extractor)
        return (service, store)
    }

    // MARK: - Fact acceptance via structured extraction

    func testAcceptFactCandidateFromStructuredExtraction() async {
        let json = """
        {"facts":[{"content":"User works at Apple","category":"work","confidence":0.9}],"episodes":[]}
        """
        let (service, _) = await makeStructuredService(responseJSON: json)

        let conversationID = UUID()
        let message = Message.user("I work at Apple on the SwiftUI team", in: conversationID)
        await service.consider(message: message)

        XCTAssertEqual(service.candidates.count, 1)
        XCTAssertEqual(service.candidates[0].kind, .fact)
        XCTAssertEqual(service.candidates[0].extractionMethod, .structured)
        XCTAssertEqual(service.candidates[0].sourceConversationID, conversationID)

        let candidate = service.candidates[0]
        await service.accept(candidate)

        XCTAssertEqual(service.facts.count, 1)
        XCTAssertEqual(service.facts[0].content, "User works at Apple")
        XCTAssertEqual(service.facts[0].category, .work)
        XCTAssertEqual(service.facts[0].source, .conversationExtraction)
        XCTAssertEqual(service.facts[0].sourceConversationID, conversationID)
        XCTAssertEqual(service.facts[0].sourceMessageID, message.id)
        XCTAssertEqual(service.facts[0].extractionMethod, .structured)
        XCTAssertTrue(service.candidates.isEmpty)
    }

    // MARK: - Episode acceptance via structured extraction

    func testAcceptEpisodeCandidateFromStructuredExtraction() async {
        let json = """
        {"facts":[],"episodes":[{"summary":"Working on a SwiftUI migration","confidence":0.85}]}
        """
        let (service, _) = await makeStructuredService(responseJSON: json)

        let conversationID = UUID()
        let message = Message.user("I'm migrating my app to SwiftUI", in: conversationID)
        await service.consider(message: message)

        XCTAssertEqual(service.candidates.count, 1)
        XCTAssertEqual(service.candidates[0].kind, .episode)

        let candidate = service.candidates[0]
        await service.accept(candidate)

        XCTAssertTrue(service.facts.isEmpty)
        XCTAssertEqual(service.episodes.count, 1)
        XCTAssertEqual(service.episodes[0].summary, "Working on a SwiftUI migration")
        XCTAssertEqual(service.episodes[0].sourceConversationID, conversationID)
        XCTAssertTrue(service.episodes[0].approved)
        XCTAssertTrue(service.candidates.isEmpty)
    }

    // MARK: - Heuristic extraction produces candidates

    func testConsiderWithHeuristicTriggerProducesCandidates() async {
        let (service, _) = makeHeuristicService()

        let message = Message.user("My name is Alex and I work at Apple", in: UUID())
        await service.consider(message: message)

        XCTAssertFalse(service.candidates.isEmpty)
        XCTAssertTrue(service.candidates.allSatisfy { $0.extractionMethod == .heuristic })
        XCTAssertTrue(service.candidates.allSatisfy { $0.kind == .fact })
    }

    // MARK: - Episode CRUD

    func testEpisodeDisableToggle() async {
        let (service, _) = makeHeuristicService()

        let episode = MemoryEpisode(
            id: UUID(), summary: "Test episode",
            sourceConversationID: UUID(), sourceMessageID: UUID(),
            createdAt: .now, lastRelevantAt: nil,
            approved: true, disabled: false,
            extractionMethod: .structured
        )
        await service.add(episode)
        XCTAssertFalse(service.episodes[0].disabled)

        await service.setEpisodeDisabled(true, for: episode.id)
        XCTAssertTrue(service.episodes[0].disabled)
    }

    func testDeleteEpisode() async {
        let (service, _) = makeHeuristicService()

        let episode = MemoryEpisode(
            id: UUID(), summary: "Test episode",
            sourceConversationID: UUID(), sourceMessageID: UUID(),
            createdAt: .now, lastRelevantAt: nil,
            approved: true, disabled: false,
            extractionMethod: .structured
        )
        await service.add(episode)
        XCTAssertEqual(service.episodes.count, 1)

        await service.deleteEpisode(episode.id)
        XCTAssertTrue(service.episodes.isEmpty)
    }

    // MARK: - Clear all

    func testClearAllRemovesFactsAndEpisodes() async {
        let (service, _) = makeHeuristicService()

        await service.add(MemoryFact(
            id: UUID(), content: "Test fact",
            category: .other, source: .userManual,
            confidence: 1.0, createdAt: .now,
            lastUsedAt: nil, pinned: false, disabled: false
        ))
        await service.add(MemoryEpisode(
            id: UUID(), summary: "Test episode",
            sourceConversationID: UUID(), sourceMessageID: UUID(),
            createdAt: .now, lastRelevantAt: nil,
            approved: true, disabled: false,
            extractionMethod: .heuristic
        ))

        XCTAssertEqual(service.facts.count, 1)
        XCTAssertEqual(service.episodes.count, 1)

        await service.clearAll()

        XCTAssertTrue(service.facts.isEmpty)
        XCTAssertTrue(service.episodes.isEmpty)
    }

    // MARK: - Episode retrieval

    func testRelevantEpisodesFiltersDisabled() async {
        let (service, _) = makeHeuristicService()

        let episode = MemoryEpisode(
            id: UUID(),
            summary: "Working on SwiftUI migration project",
            sourceConversationID: UUID(), sourceMessageID: UUID(),
            createdAt: .now, lastRelevantAt: nil,
            approved: true, disabled: true,
            extractionMethod: .structured
        )
        await service.add(episode)

        let relevant = await service.relevantEpisodes(for: "SwiftUI", limit: 5)
        XCTAssertTrue(relevant.isEmpty, "Disabled episodes should not be returned")
    }

    func testRelevantEpisodesFiltersUnapproved() async {
        let (service, _) = makeHeuristicService()

        let episode = MemoryEpisode(
            id: UUID(),
            summary: "Working on SwiftUI migration project",
            sourceConversationID: UUID(), sourceMessageID: UUID(),
            createdAt: .now, lastRelevantAt: nil,
            approved: false, disabled: false,
            extractionMethod: .structured
        )
        await service.add(episode)

        let relevant = await service.relevantEpisodes(for: "SwiftUI", limit: 5)
        XCTAssertTrue(relevant.isEmpty, "Unapproved episodes should not be returned")
    }

    func testRelevantEpisodesKeywordScoring() async {
        let (service, _) = makeHeuristicService()

        await service.add(MemoryEpisode(
            id: UUID(),
            summary: "Working on SwiftUI migration project",
            sourceConversationID: UUID(), sourceMessageID: UUID(),
            createdAt: .now, lastRelevantAt: nil,
            approved: true, disabled: false,
            extractionMethod: .structured
        ))
        await service.add(MemoryEpisode(
            id: UUID(),
            summary: "Planning vacation to Japan next summer",
            sourceConversationID: UUID(), sourceMessageID: UUID(),
            createdAt: .now, lastRelevantAt: nil,
            approved: true, disabled: false,
            extractionMethod: .structured
        ))

        let relevant = await service.relevantEpisodes(for: "SwiftUI project update", limit: 5)
        XCTAssertTrue(relevant.contains(where: { $0.summary.contains("SwiftUI") }))
        XCTAssertFalse(relevant.contains(where: { $0.summary.contains("Japan") }))
    }

    // MARK: - Reject

    func testRejectRemovesCandidate() async {
        let (service, _) = makeHeuristicService()

        let message = Message.user("My name is Alex", in: UUID())
        await service.consider(message: message)
        XCTAssertFalse(service.candidates.isEmpty)

        let candidateID = service.candidates[0].id
        service.reject(candidateID: candidateID)
        XCTAssertTrue(service.candidates.isEmpty)
    }

    func testRejectAllCandidates() async {
        let (service, _) = makeHeuristicService()

        let message = Message.user("My name is Alex and I work at Apple", in: UUID())
        await service.consider(message: message)
        XCTAssertFalse(service.candidates.isEmpty)

        service.rejectAllCandidates()
        XCTAssertTrue(service.candidates.isEmpty)
    }

    // MARK: - Load persists episodes

    func testLoadRecoversPersistedEpisodes() async {
        let store = InMemoryStore.empty()
        let episode = MemoryEpisode(
            id: UUID(), summary: "Persisted episode",
            sourceConversationID: UUID(), sourceMessageID: UUID(),
            createdAt: .now, lastRelevantAt: nil,
            approved: true, disabled: false,
            extractionMethod: .structured
        )
        try? await store.save(episode: episode)

        let settings = SettingsService(store: store)
        let extractor = MemoryExtractionService(runtime: nil)
        let service = MemoryService(store: store, settings: settings, extractor: extractor)
        await service.load()

        XCTAssertEqual(service.episodes.count, 1)
        XCTAssertEqual(service.episodes[0].summary, "Persisted episode")
    }
}
