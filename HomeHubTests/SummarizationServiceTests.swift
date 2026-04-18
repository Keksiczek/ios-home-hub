import XCTest
@testable import HomeHub

// MARK: - Parameter-capturing stub runtime

/// Records the last prompt and parameters passed to generate(),
/// then yields the pre-configured response text.
private final class CapturingRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "capturing"
    var loadedModel: LocalModel?
    var responseText: String = "A concise summary."
    private(set) var lastPrompt: RuntimePrompt?
    private(set) var lastParameters: RuntimeParameters?

    func load(model: LocalModel) async throws { loadedModel = model }
    func unload() async { loadedModel = nil }

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        lastPrompt = prompt
        lastParameters = parameters
        let text = responseText
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(text))
            continuation.yield(.finished(
                reason: .stop,
                stats: RuntimeStats(tokensGenerated: 5, tokensPerSecond: 50, totalDurationMs: 100)
            ))
            continuation.finish()
        }
    }
}

// MARK: - Tests

/// Regression tests for `SummarizationService`.
///
/// ## What these tests guard
/// 1. Returns `nil` when no model is loaded.
/// 2. Returns `nil` for an empty message list.
/// 3. Returns the runtime's response text (trimmed).
/// 4. Uses temperature 0.2 and maxTokens 200 (tight budget).
/// 5. System prompt contains "conversation summarizer".
/// 6. System messages in the history are excluded from the transcript.
/// 7. Returns `nil` when the runtime returns an empty string.
/// 8. Whitespace-only response is treated as nil.
@MainActor
final class SummarizationServiceTests: XCTestCase {

    private let stubModel = LocalModel(
        id: "sum-test-model",
        displayName: "Summary Test",
        family: "test",
        parameterCount: "1B",
        quantization: "q4",
        sizeBytes: 1_000_000,
        contextLength: 2048,
        downloadURL: URL(string: "https://example.com/model.gguf")!,
        sha256: nil,
        installState: .installed(localURL: URL(fileURLWithPath: "/tmp/sum.gguf")),
        recommendedFor: [],
        license: "MIT"
    )

    // MARK: - Nil guards

    func testReturnsNilWhenNoModelLoaded() async {
        let rt = CapturingRuntime()
        // No load() call → activeModel stays nil in RuntimeManager
        let manager = RuntimeManager(runtime: rt)
        let service = SummarizationService(runtime: manager)

        let result = await service.summarize(messages: [makeMessage()])
        XCTAssertNil(result,
            "summarize must return nil when no model is loaded")
    }

    func testReturnsNilForEmptyMessageList() async {
        let rt = CapturingRuntime()
        let manager = RuntimeManager(runtime: rt)
        await manager.load(stubModel)
        let service = SummarizationService(runtime: manager)

        let result = await service.summarize(messages: [])
        XCTAssertNil(result, "summarize must return nil for an empty message list")
    }

    func testReturnsNilForEmptyRuntimeResponse() async {
        let rt = CapturingRuntime()
        rt.responseText = ""
        let manager = RuntimeManager(runtime: rt)
        await manager.load(stubModel)
        let service = SummarizationService(runtime: manager)

        let result = await service.summarize(messages: [makeMessage("Some content")])
        XCTAssertNil(result, "Empty runtime response must map to nil")
    }

    func testReturnsNilForWhitespaceOnlyResponse() async {
        let rt = CapturingRuntime()
        rt.responseText = "   \n\n   "
        let manager = RuntimeManager(runtime: rt)
        await manager.load(stubModel)
        let service = SummarizationService(runtime: manager)

        let result = await service.summarize(messages: [makeMessage("Some content")])
        XCTAssertNil(result, "Whitespace-only response must map to nil")
    }

    // MARK: - Output

    func testReturnsTrimmedRuntimeOutput() async {
        let rt = CapturingRuntime()
        rt.responseText = "  The project is about X.  "
        let manager = RuntimeManager(runtime: rt)
        await manager.load(stubModel)
        let service = SummarizationService(runtime: manager)

        let result = await service.summarize(messages: [makeMessage("Tell me about X")])
        XCTAssertEqual(result, "The project is about X.")
    }

    // MARK: - Parameters (tight summarisation budget)

    func testUsesLowTemperature() async {
        let rt = CapturingRuntime()
        let manager = RuntimeManager(runtime: rt)
        await manager.load(stubModel)
        let service = SummarizationService(runtime: manager)

        _ = await service.summarize(messages: [makeMessage("Something to summarize")])
        XCTAssertEqual(rt.lastParameters?.temperature, 0.2,
            "Summarization must use T=0.2 for deterministic output")
    }

    func testUsesMaxTokens200() async {
        let rt = CapturingRuntime()
        let manager = RuntimeManager(runtime: rt)
        await manager.load(stubModel)
        let service = SummarizationService(runtime: manager)

        _ = await service.summarize(messages: [makeMessage("Something to summarize")])
        XCTAssertEqual(rt.lastParameters?.maxTokens, 200,
            "Summarization must cap output at 200 tokens")
    }

    // MARK: - System prompt

    func testSystemPromptContainsSummarizerInstruction() async {
        let rt = CapturingRuntime()
        let manager = RuntimeManager(runtime: rt)
        await manager.load(stubModel)
        let service = SummarizationService(runtime: manager)

        _ = await service.summarize(messages: [makeMessage("A user message")])
        XCTAssertTrue(rt.lastPrompt?.systemPrompt.contains("conversation summarizer") == true,
            "System prompt must identify the summarization role")
    }

    func testSystemPromptMentionsWordLimit() async {
        let rt = CapturingRuntime()
        let manager = RuntimeManager(runtime: rt)
        await manager.load(stubModel)
        let service = SummarizationService(runtime: manager)

        _ = await service.summarize(messages: [makeMessage("A user message")])
        XCTAssertTrue(rt.lastPrompt?.systemPrompt.contains("120 words") == true,
            "System prompt must include the 120-word limit")
    }

    // MARK: - Role filtering

    func testSystemMessagesAreExcludedFromTranscript() async {
        let rt = CapturingRuntime()
        let manager = RuntimeManager(runtime: rt)
        await manager.load(stubModel)
        let service = SummarizationService(runtime: manager)

        let messages = [
            makeMessage("User turn", role: .user),
            makeMessage("You are an assistant.", role: .system),
            makeMessage("Assistant turn", role: .assistant)
        ]
        _ = await service.summarize(messages: messages)

        // The user-input message sent to the runtime should NOT contain
        // the system message content.
        let userInput = rt.lastPrompt?.messages.last?.content ?? ""
        XCTAssertFalse(userInput.contains("You are an assistant."),
            "System role messages must be excluded from the summarization transcript")
    }

    // MARK: - Helpers

    private func makeMessage(
        _ content: String = "Hello, I have a question.",
        role: Message.Role = .user
    ) -> Message {
        Message(
            id: UUID(),
            conversationID: UUID(),
            role: role,
            content: content,
            createdAt: .now,
            status: .complete,
            tokenCount: nil
        )
    }
}
