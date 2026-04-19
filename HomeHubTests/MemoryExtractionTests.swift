import XCTest
@testable import HomeHub

// MARK: - Controllable test runtime

/// A minimal runtime for extraction tests that returns a pre-set
/// response string. Avoids dependency on MockLocalRuntime's canned
/// responses.
private final class StubRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "stub"
    var loadedModel: LocalModel?
    var responseText: String = ""

    func load(model: LocalModel) async throws {
        loadedModel = model
    }

    func unload() async {
        loadedModel = nil
    }

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

/// A stub runtime that always throws during generation.
private final class FailingRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "failing"
    var loadedModel: LocalModel?

    func load(model: LocalModel) async throws {
        loadedModel = model
    }

    func unload() async {
        loadedModel = nil
    }

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: RuntimeError.underlying("Simulated failure"))
        }
    }
}

private let stubModel = LocalModel(
    id: "test-model",
    displayName: "Test Model",
    family: "test",
    parameterCount: "1B",
    quantization: "q4",
    sizeBytes: 1_000_000,
    contextLength: 2048,
    downloadURL: URL(string: "https://example.com/model.gguf")!,
    sha256: nil,
    installState: .installed(localURL: URL(fileURLWithPath: "/tmp/test.gguf")),
    recommendedFor: [.iPhone],
    license: "MIT"
)

// MARK: - Tests

@MainActor
final class MemoryExtractionTests: XCTestCase {

    // MARK: - Structured LLM extraction (Layer 3)

    /// Uses a message with no keyword triggers and no recognisable named
    /// entities so Layers 1+2 return empty and Layer 3 actually fires.
    private func noTriggerMessage(in convoID: UUID = UUID()) -> Message {
        Message.user(
            "I have been feeling stressed about deadlines and thinking about changing my daily routine entirely",
            in: convoID
        )
    }

    /// Wraps a stub runtime in a fully-loaded `RuntimeManager` so the
    /// extractor sees `activeModel != nil`. Used by every Layer-3 test.
    private func loadedManager(_ runtime: any LocalLLMRuntime) async -> RuntimeManager {
        let manager = RuntimeManager(runtime: runtime)
        await manager.load(stubModel)
        return manager
    }

    func testStructuredExtractionProducesFactAndEpisodeCandidates() async {
        let runtime = StubRuntime()
        runtime.responseText = """
        {"facts":[{"content":"User is stressed about deadlines","category":"work","confidence":0.9}],"episodes":[{"summary":"Considering changing daily routine","confidence":0.85}]}
        """
        let manager = await loadedManager(runtime)

        let extractor = MemoryExtractionService(runtime: manager)
        let candidates = await extractor.extract(from: noTriggerMessage())

        let structured = candidates.filter { $0.extractionMethod == .structured }
        XCTAssertEqual(structured.count, 2)
        XCTAssertEqual(structured[0].kind, .fact)
        XCTAssertEqual(structured[0].content, "User is stressed about deadlines")
        XCTAssertEqual(structured[1].kind, .episode)
        XCTAssertEqual(structured[1].content, "Considering changing daily routine")
    }

    func testStructuredExtractionHandlesMarkdownFencing() async {
        let runtime = StubRuntime()
        runtime.responseText = """
        ```json
        {"facts":[{"content":"Stressed about deadlines","category":"work","confidence":0.9}],"episodes":[]}
        ```
        """
        let manager = await loadedManager(runtime)

        let extractor = MemoryExtractionService(runtime: manager)
        let candidates = await extractor.extract(from: noTriggerMessage())

        let structured = candidates.filter { $0.extractionMethod == .structured }
        XCTAssertEqual(structured.count, 1)
        XCTAssertEqual(structured[0].content, "Stressed about deadlines")
    }

    func testStructuredExtractionHandlesProseWrappedJSON() async {
        let runtime = StubRuntime()
        runtime.responseText = """
        Here is the extraction:
        {"facts":[{"content":"Wants to change routine","category":"preferences","confidence":0.8}],"episodes":[]}
        That's all I found.
        """
        let manager = await loadedManager(runtime)

        let extractor = MemoryExtractionService(runtime: manager)
        let candidates = await extractor.extract(from: noTriggerMessage())

        let structured = candidates.filter { $0.extractionMethod == .structured }
        XCTAssertEqual(structured.count, 1)
        XCTAssertEqual(structured[0].content, "Wants to change routine")
    }

    // MARK: - Pipeline layering

    func testHeuristicTriggersPreventLLMFromRunning() async {
        let runtime = StubRuntime()
        runtime.responseText = """
        {"facts":[{"content":"Should not appear","category":"other","confidence":0.9}],"episodes":[]}
        """
        let manager = await loadedManager(runtime)

        let extractor = MemoryExtractionService(runtime: manager)
        let message = Message.user("My name is Alex and I work at a tech company", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertFalse(candidates.isEmpty,
            "Heuristic layer should produce candidates")
        XCTAssertTrue(candidates.allSatisfy { $0.extractionMethod != .structured },
            "LLM layer should not run when heuristic layer found candidates")
    }

    func testShortMessageSkipsLLMEvenWithoutCheapResults() async {
        let runtime = StubRuntime()
        runtime.responseText = """
        {"facts":[{"content":"Should not appear","category":"other","confidence":0.9}],"episodes":[]}
        """
        let manager = await loadedManager(runtime)

        let extractor = MemoryExtractionService(runtime: manager)
        let message = Message.user("How are you today?", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertTrue(candidates.isEmpty,
            "Short messages without triggers should produce no candidates at all")
    }

    func testLLMEscalationOnLongMessageWithoutCheapResults() async {
        let runtime = StubRuntime()
        runtime.responseText = """
        {"facts":[{"content":"Stressed about deadlines","category":"work","confidence":0.8}],"episodes":[]}
        """
        let manager = await loadedManager(runtime)

        let extractor = MemoryExtractionService(runtime: manager)
        let candidates = await extractor.extract(from: noTriggerMessage())

        let structured = candidates.filter { $0.extractionMethod == .structured }
        XCTAssertFalse(structured.isEmpty,
            "LLM layer should run when cheap layers found nothing on a long message")
    }

    func testLLMFailureReturnsEmptyWhenNoCheapResults() async {
        let manager = await loadedManager(FailingRuntime())

        let extractor = MemoryExtractionService(runtime: manager)
        let candidates = await extractor.extract(from: noTriggerMessage())

        XCTAssertTrue(candidates.isEmpty,
            "When all layers fail, result should be empty")
    }

    // MARK: - Heuristic-only paths

    func testHeuristicRunsWithoutRuntime() async {
        let extractor = MemoryExtractionService(runtime: nil)
        let message = Message.user("My name is Alex and I work at Apple", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.extractionMethod == .heuristic })
    }

    func testHeuristicRunsWhenNoModelLoaded() async {
        // RuntimeManager constructed without a load() call → activeModel == nil,
        // so Layer 3 must be skipped even though a runtime is wired in.
        let manager = RuntimeManager(runtime: StubRuntime())
        let extractor = MemoryExtractionService(runtime: manager)
        let message = Message.user("My name is Alex", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.extractionMethod == .heuristic })
    }

    // MARK: - Heuristic extraction behavior

    func testHeuristicExtractsFromKnownTriggers() async {
        let extractor = MemoryExtractionService(runtime: nil)

        let message = Message.user("I work at Apple and I'm building a new iOS app", in: UUID())
        let candidates = await extractor.extract(from: message)

        let categories = Set(candidates.map(\.category))
        XCTAssertTrue(categories.contains(.work))
        XCTAssertTrue(categories.contains(.projects))
    }

    func testHeuristicReturnsEmptyForNoTriggers() async {
        let extractor = MemoryExtractionService(runtime: nil)
        let message = Message.user("What's the weather like?", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertTrue(candidates.isEmpty)
    }

    func testHeuristicIgnoresAssistantMessages() async {
        let extractor = MemoryExtractionService(runtime: nil)
        let message = Message(
            id: UUID(), conversationID: UUID(),
            role: .assistant, content: "My name is Home",
            createdAt: .now, status: .complete, tokenCount: nil
        )
        let candidates = await extractor.extract(from: message)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testHeuristicDeduplicatesByCategory() async {
        let extractor = MemoryExtractionService(runtime: nil)
        // Two triggers for the same category (personal)
        let message = Message.user("My name is Alex and I live in NYC", in: UUID())
        let candidates = await extractor.extract(from: message)

        let personalCount = candidates.filter { $0.category == .personal }.count
        XCTAssertEqual(personalCount, 1) // deduplicated
    }

    // MARK: - JSON extraction helper

    func testExtractJSONFromCleanJSON() {
        let input = """
        {"facts":[],"episodes":[]}
        """
        let result = MemoryExtractionService.extractJSON(from: input)
        XCTAssertTrue(result.hasPrefix("{"))
        XCTAssertTrue(result.hasSuffix("}"))
    }

    func testExtractJSONFromMarkdownFenced() {
        let input = """
        ```json
        {"facts":[],"episodes":[]}
        ```
        """
        let result = MemoryExtractionService.extractJSON(from: input)
        XCTAssertEqual(result, "{\"facts\":[],\"episodes\":[]}")
    }

    func testExtractJSONFromProseWrapped() {
        let input = """
        Here is the result:
        {"facts":[{"content":"test","category":"work"}],"episodes":[]}
        Done.
        """
        let result = MemoryExtractionService.extractJSON(from: input)
        XCTAssertTrue(result.hasPrefix("{"))
        XCTAssertTrue(result.hasSuffix("}"))
    }

    // MARK: - Provenance

    func testCandidatesHaveCorrectProvenance() async {
        let conversationID = UUID()
        let extractor = MemoryExtractionService(runtime: nil)
        let message = Message.user("My name is Alex", in: conversationID)
        let candidates = await extractor.extract(from: message)

        for candidate in candidates {
            XCTAssertEqual(candidate.sourceConversationID, conversationID)
            XCTAssertEqual(candidate.sourceMessageID, message.id)
        }
    }
}
