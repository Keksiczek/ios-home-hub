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

final class MemoryExtractionTests: XCTestCase {

    // MARK: - Structured extraction

    func testStructuredExtractionProducesFactAndEpisodeCandidates() async {
        let runtime = StubRuntime()
        await runtime.load(model: stubModel) // mark as loaded
        runtime.responseText = """
        {"facts":[{"content":"User is a product designer","category":"work","confidence":0.9}],"episodes":[{"summary":"Working on a meditation app","confidence":0.85}]}
        """

        let extractor = MemoryExtractionService(runtime: runtime)
        let message = Message.user("I'm a product designer building a meditation app", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].kind, .fact)
        XCTAssertEqual(candidates[0].content, "User is a product designer")
        XCTAssertEqual(candidates[0].category, .work)
        XCTAssertEqual(candidates[0].extractionMethod, .structured)
        XCTAssertEqual(candidates[1].kind, .episode)
        XCTAssertEqual(candidates[1].content, "Working on a meditation app")
        XCTAssertEqual(candidates[1].extractionMethod, .structured)
    }

    func testStructuredExtractionHandlesMarkdownFencing() async {
        let runtime = StubRuntime()
        await runtime.load(model: stubModel)
        runtime.responseText = """
        ```json
        {"facts":[{"content":"Lives in San Francisco","category":"personal","confidence":0.9}],"episodes":[]}
        ```
        """

        let extractor = MemoryExtractionService(runtime: runtime)
        let message = Message.user("I live in San Francisco", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].content, "Lives in San Francisco")
    }

    func testStructuredExtractionHandlesProseWrappedJSON() async {
        let runtime = StubRuntime()
        await runtime.load(model: stubModel)
        runtime.responseText = """
        Here is the extraction:
        {"facts":[{"content":"Prefers dark mode","category":"preferences","confidence":0.8}],"episodes":[]}
        That's all I found.
        """

        let extractor = MemoryExtractionService(runtime: runtime)
        let message = Message.user("I prefer dark mode", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].content, "Prefers dark mode")
    }

    // MARK: - Fallback to heuristic

    func testFallsBackToHeuristicWhenNoRuntimeProvided() async {
        let extractor = MemoryExtractionService(runtime: nil)
        let message = Message.user("My name is Alex and I work at Apple", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.extractionMethod == .heuristic })
        XCTAssertTrue(candidates.allSatisfy { $0.kind == .fact })
    }

    func testFallsBackToHeuristicWhenNoModelLoaded() async {
        let runtime = StubRuntime()
        // Don't load a model — loadedModel remains nil
        let extractor = MemoryExtractionService(runtime: runtime)
        let message = Message.user("My name is Alex", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.extractionMethod == .heuristic })
    }

    func testFallsBackToHeuristicWhenRuntimeFails() async {
        let runtime = FailingRuntime()
        await runtime.load(model: stubModel)

        let extractor = MemoryExtractionService(runtime: runtime)
        let message = Message.user("My name is Alex", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.extractionMethod == .heuristic })
    }

    func testFallsBackToHeuristicOnInvalidJSON() async {
        let runtime = StubRuntime()
        await runtime.load(model: stubModel)
        runtime.responseText = "I don't know how to extract memory from that."

        let extractor = MemoryExtractionService(runtime: runtime)
        let message = Message.user("My name is Alex", in: UUID())
        let candidates = await extractor.extract(from: message)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.extractionMethod == .heuristic })
    }

    func testFallsBackToHeuristicOnEmptyStructuredResult() async {
        let runtime = StubRuntime()
        await runtime.load(model: stubModel)
        runtime.responseText = """
        {"facts":[],"episodes":[]}
        """

        let extractor = MemoryExtractionService(runtime: runtime)
        // This message has a heuristic trigger
        let message = Message.user("My name is Alex", in: UUID())
        let candidates = await extractor.extract(from: message)

        // Structured returned empty → falls through to heuristic
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
