import XCTest
@testable import HomeHub

/// Tests that every entity type survives a save → load roundtrip
/// through InMemoryStore (same semantics as FileStore but without
/// touching disk, making tests fast and hermetic).
final class PersistenceRoundtripTests: XCTestCase {

    // MARK: - UserProfile

    func testUserProfileRoundTrip() async throws {
        let store = InMemoryStore.empty()
        let profile = UserProfile(
            id: UUID(),
            displayName: "Alex",
            pronouns: "they/them",
            occupation: "Designer",
            locale: "en_US",
            interests: ["typography", "espresso"],
            workingContext: "Launching an app",
            preferredResponseStyle: .balanced,
            createdAt: .now,
            updatedAt: .now
        )

        try await store.save(userProfile: profile)
        let loaded = try await store.loadUserProfile()

        XCTAssertEqual(loaded?.displayName, "Alex")
        XCTAssertEqual(loaded?.interests, ["typography", "espresso"])
        XCTAssertEqual(loaded?.preferredResponseStyle, .balanced)
    }

    // MARK: - AssistantProfile

    func testAssistantProfileRoundTrip() async throws {
        let store = InMemoryStore.empty()
        let assistant = AssistantProfile.defaultAssistant

        try await store.save(assistant: assistant)
        let loaded = try await store.loadAssistantProfile()

        XCTAssertEqual(loaded?.name, "Home")
        XCTAssertEqual(loaded?.tone, .calm)
    }

    // MARK: - Conversation + Messages

    func testConversationRoundTrip() async throws {
        let store = InMemoryStore.empty()
        let convo = Conversation.new(
            assistantID: UUID(), modelID: "test-model", title: "Test chat"
        )

        try await store.save(conversation: convo)
        let loaded = try await store.loadConversations()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Test chat")
    }

    func testMessageRoundTrip() async throws {
        let store = InMemoryStore.empty()
        let convoID = UUID()
        let msg = Message.user("Hello world", in: convoID)

        try await store.save(message: msg)
        let loaded = try await store.loadMessages(conversationID: convoID)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, "Hello world")
        XCTAssertEqual(loaded[0].role, .user)
    }

    func testDeleteConversationRemovesMessages() async throws {
        let store = InMemoryStore.empty()
        let convo = Conversation.new(
            assistantID: UUID(), modelID: "test", title: "To delete"
        )
        let msg = Message.user("Hi", in: convo.id)

        try await store.save(conversation: convo)
        try await store.save(message: msg)

        try await store.delete(conversationID: convo.id)

        let convos = try await store.loadConversations()
        let messages = try await store.loadMessages(conversationID: convo.id)

        XCTAssertTrue(convos.isEmpty)
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - MemoryFact

    func testMemoryFactRoundTrip() async throws {
        let store = InMemoryStore.empty()
        let fact = MemoryFact(
            id: UUID(), content: "Works at Apple",
            category: .work, source: .conversationExtraction,
            confidence: 0.9, createdAt: .now, lastUsedAt: nil,
            pinned: true, disabled: false,
            sourceConversationID: UUID(),
            sourceMessageID: UUID(),
            extractionMethod: .structured
        )

        try await store.save(fact: fact)
        let loaded = try await store.loadMemoryFacts()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, "Works at Apple")
        XCTAssertTrue(loaded[0].pinned)
        XCTAssertEqual(loaded[0].extractionMethod, .structured)
    }

    func testDeleteMemoryFact() async throws {
        let store = InMemoryStore.empty()
        let fact = MemoryFact(
            id: UUID(), content: "Test",
            category: .other, source: .userManual,
            confidence: 1.0, createdAt: .now, lastUsedAt: nil,
            pinned: false, disabled: false
        )

        try await store.save(fact: fact)
        try await store.deleteMemoryFact(id: fact.id)
        let loaded = try await store.loadMemoryFacts()

        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - MemoryEpisode

    func testMemoryEpisodeRoundTrip() async throws {
        let store = InMemoryStore.empty()
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
        let loaded = try await store.loadMemoryEpisodes()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].summary, "Planning a trip to Japan")
        XCTAssertTrue(loaded[0].approved)
    }

    // MARK: - AppSettings

    func testAppSettingsRoundTrip() async throws {
        let store = InMemoryStore.empty()
        var settings = AppSettings.default
        settings.temperature = 0.5
        settings.memoryEnabled = false
        settings.selectedModelID = "llama-3.2-3b-instruct-q4_k_m"

        try await store.save(settings: settings)
        let loaded = try await store.loadAppSettings()

        XCTAssertEqual(loaded?.temperature, 0.5)
        XCTAssertEqual(loaded?.memoryEnabled, false)
        XCTAssertEqual(loaded?.selectedModelID, "llama-3.2-3b-instruct-q4_k_m")
    }

    func testAppSettingsSelectedModelIDDefaultsToNil() {
        let settings = AppSettings.default
        XCTAssertNil(settings.selectedModelID)
    }

    // MARK: - OnboardingState

    func testOnboardingStateRoundTrip() async throws {
        let store = InMemoryStore.empty()
        let state = OnboardingState(isCompleted: true, currentStep: .finish)

        try await store.save(onboardingState: state)
        let loaded = try await store.loadOnboardingState()

        XCTAssertEqual(loaded?.isCompleted, true)
        XCTAssertEqual(loaded?.currentStep, .finish)
    }

    // MARK: - Message update (upsert)

    func testMessageUpdateReplacesExisting() async throws {
        let store = InMemoryStore.empty()
        let convoID = UUID()
        var msg = Message.assistantPlaceholder(in: convoID)

        try await store.save(message: msg)

        msg.content = "Generated response text"
        msg.status = .complete
        try await store.save(message: msg)

        let loaded = try await store.loadMessages(conversationID: convoID)
        XCTAssertEqual(loaded.count, 1, "Should update in place, not duplicate")
        XCTAssertEqual(loaded[0].content, "Generated response text")
        XCTAssertEqual(loaded[0].status, .complete)
    }

    // MARK: - Conversation update (upsert)

    func testConversationUpdateReplacesExisting() async throws {
        let store = InMemoryStore.empty()
        var convo = Conversation.new(
            assistantID: UUID(), modelID: "test", title: "Original"
        )

        try await store.save(conversation: convo)

        convo.title = "Updated"
        convo.lastMessagePreview = "Hello"
        try await store.save(conversation: convo)

        let loaded = try await store.loadConversations()
        XCTAssertEqual(loaded.count, 1, "Should update in place, not duplicate")
        XCTAssertEqual(loaded[0].title, "Updated")
        XCTAssertEqual(loaded[0].lastMessagePreview, "Hello")
    }
}
