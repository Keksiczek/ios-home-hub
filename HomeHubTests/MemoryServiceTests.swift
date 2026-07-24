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
        runtime.responseText = responseJSON
        // `MemoryExtractionService` gates structured extraction on
        // `RuntimeManager.activeModel != nil` (see its `consider`), and
        // `activeModel` is only set by `RuntimeManager.load(_:)` — not by
        // calling `load` on the underlying runtime directly.
        //
        // The old setup loaded the stub directly (`runtime.load(model:)`), so
        // the facade's `activeModel` stayed nil, structured extraction was
        // skipped, and every structured-extraction test silently fell back to
        // the heuristic path and produced zero candidates — then crashed on the
        // `candidates[0]` that followed the failed count assertion. Loading
        // through the manager is what production does.
        let runtimeManager = RuntimeManager(runtime: runtime)
        await runtimeManager.load(stubModel)
        let extractor = MemoryExtractionService(runtime: runtimeManager)
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
        // The message must REACH Layer 3, which means clearing two gates in
        // `MemoryExtractionService.extract`: `candidates.isEmpty` (no Layer-1
        // trigger, no Layer-2 proper noun) and `count >= llmMinMessageLength`
        // (40).
        //
        // The original fixture — "I work at Apple on the SwiftUI team" — failed
        // both: 35 characters, and "i work at" is a Layer-1 trigger. So the
        // pipeline answered from the heuristic layer and never called the LLM,
        // and the test asserted `.structured` against a `.heuristic` candidate.
        // The extraction pipeline was inverted to cheapest-first in 093f6f7;
        // this file predates that and was never adapted.
        //
        // The assertions below check the STUB's JSON, not the message text, so
        // the wording is free to change.
        let message = Message.user(
            "The kitchen light stays on much longer than it needs to",
            in: conversationID
        )
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
        // Same Layer-3 gate as the fact test above. The original fixture
        // ("I'm migrating my app to SwiftUI") was 31 characters — under
        // `llmMinMessageLength` — so structured extraction never ran.
        let message = Message.user(
            "Spent most of the afternoon reorganising the cupboards",
            in: conversationID
        )
        await service.consider(message: message)

        XCTAssertEqual(service.candidates.count, 1)
        // Guard the index so a count regression reports as a clean assertion
        // failure instead of an "Index out of range" trap that restarts the
        // whole test runner (which is what made this failure so costly).
        guard let candidate = service.candidates.first else {
            return XCTFail("expected one episode candidate, got \(service.candidates.count)")
        }
        XCTAssertEqual(candidate.kind, .episode)
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
        // Layer 2 (NLTagger) runs ADDITIVELY after Layer 1, skipping only
        // categories Layer 1 already covered. "Alex" tags as a personal name →
        // `.relationships`, which the triggers here don't cover, so a
        // `.naturalLanguage` candidate legitimately joins the heuristic ones.
        //
        // `allSatisfy { == .heuristic }` therefore asserted something the
        // pipeline never promised, and its outcome depended on NLTagger's
        // OS-version behaviour. What this test actually cares about is that the
        // cheap layers answered and the LLM was never consulted.
        XCTAssertTrue(
            service.candidates.contains { $0.extractionMethod == .heuristic },
            "the keyword trigger should have produced at least one candidate"
        )
        XCTAssertFalse(
            service.candidates.contains { $0.extractionMethod == .structured },
            "cheap layers matched, so Layer 3 must not have run"
        )
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

        // `reject` removes exactly one candidate by ID, so asserting the list
        // is empty afterwards only holds when there was exactly one to begin
        // with. Layer 2 can add a `.relationships` candidate for "Alex"
        // alongside the Layer-1 `.personal` one, making the count
        // NLTagger-dependent. Assert what `reject` actually contracts: that
        // *this* candidate is gone and exactly one was removed.
        let before = service.candidates.count
        let candidateID = service.candidates[0].id
        service.reject(candidateID: candidateID)
        XCTAssertFalse(service.candidates.contains { $0.id == candidateID })
        XCTAssertEqual(service.candidates.count, before - 1)
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
