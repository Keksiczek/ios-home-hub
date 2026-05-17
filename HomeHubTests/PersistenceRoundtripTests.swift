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

    // MARK: - Schema forward-compatibility
    //
    // `Message.attachments` is optional and was added after the first
    // wave of users had already persisted messages. The decoder MUST
    // tolerate JSON written before the field existed (decode to nil)
    // and round-trip a message WITHOUT attachments as nil — not as an
    // empty array. The same contract applies to `Message.tokenCount`.

    func testMessageWithoutAttachments_RoundTripsAsNil() async throws {
        let store = InMemoryStore.empty()
        let convoID = UUID()
        let msg = Message.user("No attachments here", in: convoID, attachments: nil)
        try await store.save(message: msg)

        let loaded = try await store.loadMessages(conversationID: convoID)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded[0].attachments,
            "Decoder must distinguish 'no attachments' (nil) from 'empty list' for forward-compat")
        XCTAssertNil(loaded[0].tokenCount)
    }

    func testMessageWithAttachments_RoundTripsContent() async throws {
        let store = InMemoryStore.empty()
        let convoID = UUID()
        let attachment = Message.Attachment(
            id: UUID(),
            filename: "screenshot.png",
            extractedText: "OCR'd body text from the image"
        )
        let msg = Message.user("With one attachment", in: convoID, attachments: [attachment])
        try await store.save(message: msg)

        let loaded = try await store.loadMessages(conversationID: convoID)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].attachments?.count, 1)
        XCTAssertEqual(loaded[0].attachments?.first?.filename, "screenshot.png")
        XCTAssertEqual(loaded[0].attachments?.first?.extractedText, "OCR'd body text from the image")
    }

    func testMessageDecode_FromLegacyJSON_WithoutAttachmentsKey() throws {
        // Synthetic pre-attachments JSON shape — simulates a row
        // written by an older app version. Decoder must default the
        // missing field to nil without throwing.
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "conversationID": "22222222-2222-2222-2222-222222222222",
            "role": "user",
            "content": "Hello from the past",
            "createdAt": -978307200,
            "status": "complete"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Message.self, from: legacyJSON)
        XCTAssertEqual(decoded.content, "Hello from the past")
        XCTAssertNil(decoded.attachments)
        XCTAssertNil(decoded.tokenCount)
    }
}
