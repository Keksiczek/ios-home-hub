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
}
