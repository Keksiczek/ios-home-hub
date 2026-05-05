import XCTest
@testable import HomeHub

/// Tests for the end-to-end conversation flow at the service layer:
/// create conversation → send message → streaming response →
/// persistence → memory consideration.
@MainActor
final class ConversationServiceTests: XCTestCase {

    // MARK: - Helpers

    private static let testModel = LocalModel(
        id: "test-model", displayName: "Test", family: "test",
        parameterCount: "1B", quantization: "q4", sizeBytes: 1_000_000,
        contextLength: 2048,
        downloadURL: URL(string: "https://example.com/model.gguf")!,
        sha256: nil,
        installState: .installed(localURL: URL(fileURLWithPath: "/tmp/test.gguf")),
        recommendedFor: [.iPhone], license: "MIT"
    )

    private func makeStack() async -> (
        service: ConversationService,
        runtime: RuntimeManager,
        memory: MemoryService,
        store: InMemoryStore
    ) {
        let store = InMemoryStore.empty()
        let mockRuntime = MockLocalRuntime()
        let runtimeMgr = RuntimeManager(runtime: mockRuntime)
        // Load a model so runtime.activeModel is set.
        await runtimeMgr.load(Self.testModel)

        let settings = SettingsService(store: store)
        let personalization = PersonalizationService(
            store: store,
            defaultUser: .blank,
            defaultAssistant: .defaultAssistant
        )
        let extractor = MemoryExtractionService(runtime: nil)
        let memory = MemoryService(store: store, settings: settings, extractor: extractor)
        let prompts = PromptAssemblyService()

        let service = ConversationService(
            store: store,
            runtime: runtimeMgr,
            prompts: prompts,
            memory: memory,
            settings: settings,
            personalization: personalization
        )

        return (service, runtimeMgr, memory, store)
    }

    // MARK: - Create conversation

    func testCreateConversationAddsToList() async {
        let (service, _, _, _) = await makeStack()

        let convo = await service.createConversation(title: "Test Chat")

        XCTAssertEqual(service.conversations.count, 1)
        XCTAssertEqual(service.conversations[0].id, convo.id)
        XCTAssertEqual(service.conversations[0].title, "Test Chat")
    }

    func testCreateConversationPersistsToStore() async {
        let (service, _, _, store) = await makeStack()

        let convo = await service.createConversation(title: "Persisted")

        let saved = try? await store.loadConversations()
        XCTAssertEqual(saved?.count, 1)
        XCTAssertEqual(saved?.first?.id, convo.id)
    }

    // MARK: - Send message

    func testSendProducesUserAndAssistantMessages() async throws {
        let (service, _, _, _) = await makeStack()
        let convo = await service.createConversation()

        // Send triggers the async generation. We need to wait for it.
        service.send(userInput: "Hello", in: convo.id)

        // Wait for the mock runtime to finish streaming.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let messages = service.messages(in: convo.id)
        XCTAssertGreaterThanOrEqual(messages.count, 2)

        let userMsg = messages.first { $0.role == .user }
        XCTAssertNotNil(userMsg)
        XCTAssertEqual(userMsg?.content, "Hello")

        let assistantMsg = messages.first { $0.role == .assistant }
        XCTAssertNotNil(assistantMsg)
        XCTAssertFalse(assistantMsg?.content.isEmpty ?? true,
                       "Assistant should have generated content")
        XCTAssertEqual(assistantMsg?.status, .complete)
    }

    func testSendUpdatesConversationPreview() async throws {
        let (service, _, _, _) = await makeStack()
        let convo = await service.createConversation()

        service.send(userInput: "Tell me something", in: convo.id)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let updated = service.conversations.first { $0.id == convo.id }
        XCTAssertEqual(updated?.lastMessagePreview, "Tell me something")
    }

    // MARK: - Cancel

    func testCancelStopsStreaming() async throws {
        let (service, _, _, _) = await makeStack()
        let convo = await service.createConversation()

        service.send(userInput: "Long response please", in: convo.id)
        // Give it a moment to start
        try await Task.sleep(nanoseconds: 200_000_000)

        service.cancelStream(in: convo.id)

        XCTAssertFalse(service.streamingConversationIDs.contains(convo.id))
    }

    // MARK: - Delete

    func testDeleteConversation() async {
        let (service, _, _, _) = await makeStack()
        let convo = await service.createConversation()

        await service.deleteConversation(convo.id)

        XCTAssertTrue(service.conversations.isEmpty)
        XCTAssertNil(service.messagesByConversation[convo.id])
    }

    // MARK: - Rename

    func testRenameConversation() async {
        let (service, _, _, _) = await makeStack()
        let convo = await service.createConversation(title: "Old")

        await service.rename(conversationID: convo.id, to: "New Title")

        XCTAssertEqual(service.conversations.first?.title, "New Title")
    }

    // MARK: - Load from store

    func testLoadRecoversPersistedConversations() async {
        let store = InMemoryStore.populated()
        let mockRuntime = MockLocalRuntime()
        let settings = SettingsService(store: store)
        let personalization = PersonalizationService(
            store: store, defaultUser: .blank, defaultAssistant: .defaultAssistant
        )
        let extractor = MemoryExtractionService(runtime: nil)
        let memory = MemoryService(store: store, settings: settings, extractor: extractor)
        let prompts = PromptAssemblyService()
        let runtime = RuntimeManager(runtime: mockRuntime)

        let service = ConversationService(
            store: store, runtime: runtime, prompts: prompts,
            memory: memory, settings: settings, personalization: personalization
        )
        await service.load()

        XCTAssertFalse(service.conversations.isEmpty,
                       "Should recover conversations from populated store")
    }

    // MARK: - Empty input guard

    func testSendIgnoresEmptyInput() async {
        let (service, _, _, _) = await makeStack()
        let convo = await service.createConversation()

        service.send(userInput: "   ", in: convo.id)

        let messages = service.messages(in: convo.id)
        XCTAssertTrue(messages.isEmpty, "Empty/whitespace input should be ignored")
    }

    // MARK: - Generation timeout (task 1B)

    /// A runtime that streams nothing and never finishes, simulating an unresponsive model.
    private final class HangingMockRuntime: LocalLLMRuntime, @unchecked Sendable {
        let identifier = "hanging-mock"
        private(set) var loadedModel: LocalModel?

        func load(model: LocalModel) async throws { loadedModel = model }
        func unload() async { loadedModel = nil }

        func generate(
            prompt: RuntimePrompt,
            parameters: RuntimeParameters
        ) -> AsyncThrowingStream<RuntimeEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    continuation.yield(.finished(
                        reason: .cancelled,
                        stats: RuntimeStats(tokensGenerated: 0, tokensPerSecond: 0, totalDurationMs: 0)
                    ))
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }

    private func makeHangingStack(timeoutSeconds: Int) async -> (
        service: ConversationService,
        settingsService: SettingsService,
        store: InMemoryStore
    ) {
        let store = InMemoryStore.empty()
        let runtimeMgr = RuntimeManager(runtime: HangingMockRuntime())
        await runtimeMgr.load(Self.testModel)

        let settingsService = SettingsService(store: store)
        // Seed the store with a custom timeout before the service reads it.
        var customSettings = AppSettings.default
        customSettings.generationTimeoutSeconds = timeoutSeconds
        try? await store.save(settings: customSettings)
        await settingsService.load()

        let personalization = PersonalizationService(
            store: store, defaultUser: .blank, defaultAssistant: .defaultAssistant
        )
        let extractor = MemoryExtractionService(runtime: nil)
        let memory = MemoryService(store: store, settings: settingsService, extractor: extractor)
        let prompts = PromptAssemblyService()

        let service = ConversationService(
            store: store, runtime: runtimeMgr, prompts: prompts,
            memory: memory, settings: settingsService, personalization: personalization
        )
        return (service, settingsService, store)
    }

    func testHappyPathCompletesBeforeTimeout() async throws {
        // Normal mock runtime finishes quickly — timeout must NOT fire.
        let (service, _, _, _) = await makeStack()
        let convo = await service.createConversation()

        let result = await service.sendAndWait(userInput: "Hello", in: convo.id)
        XCTAssertEqual(result, .sent)

        let messages = service.messages(in: convo.id)
        let assistant = messages.first { $0.role == .assistant }
        XCTAssertEqual(assistant?.status, .complete,
                       "Generation should complete normally without triggering timeout")
    }

    func testTimeoutMarksMessageAsFailed() async throws {
        // 1-second timeout + hanging runtime → watchdog fires quickly in CI.
        let (service, _, _) = await makeHangingStack(timeoutSeconds: 1)
        let convo = await service.createConversation()

        service.send(userInput: "This will hang", in: convo.id)

        // Allow 1 s timeout + 2 s cleanup headroom.
        try await Task.sleep(for: .seconds(3))

        let messages = service.messages(in: convo.id)
        let assistant = messages.first { $0.role == .assistant }

        XCTAssertEqual(assistant?.status, .failed,
                       "Timed-out generation must be .failed, not .cancelled")
        XCTAssertTrue(
            assistant?.content.lowercased().contains("timeout") == true,
            "Timed-out message must mention timeout; got: \(assistant?.content ?? "(nil)")"
        )
    }

    func testConversationServiceErrorIsLocalizedError() {
        let error: LocalizedError = ConversationServiceError.generationTimeout
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty == true)
    }
}
