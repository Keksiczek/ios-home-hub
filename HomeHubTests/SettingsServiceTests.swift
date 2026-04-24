import XCTest
@testable import HomeHub

/// Focused tests for the persistence contract in `SettingsService`:
/// - `load()` recovers to defaults and seeds the store when nothing
///   is persisted yet.
/// - `update()` / `set()` are save-first: a failed store write must
///   not advance `current` in memory.
@MainActor
final class SettingsServiceTests: XCTestCase {

    // MARK: - load() fallback

    func testLoadSeedsDefaultsWhenStoreIsEmpty() async throws {
        let store = InMemoryStore.empty()
        let pre = try await store.loadAppSettings()
        XCTAssertNil(pre, "Pre-condition: store should start empty.")

        let service = SettingsService(store: store)
        await service.load()

        XCTAssertEqual(service.current, .default)

        let seeded = try await store.loadAppSettings()
        XCTAssertEqual(seeded, .default,
                       "load() must persist the default settings when none were on disk.")
    }

    func testLoadKeepsExistingValidSettings() async throws {
        let store = InMemoryStore.empty()
        var custom = AppSettings.default
        custom.temperature = 0.42
        custom.memoryEnabled = false
        try await store.save(settings: custom)

        let service = SettingsService(store: store)
        await service.load()

        XCTAssertEqual(service.current.temperature, 0.42)
        XCTAssertEqual(service.current.memoryEnabled, false)
    }

    // MARK: - save-first semantics

    func testUpdateDoesNotCommitWhenSaveFails() async {
        let store = FailingSettingsStore(failSaves: true)
        let service = SettingsService(store: store)
        await service.load() // Seeds defaults in memory; save fails silently.

        XCTAssertEqual(service.current.temperature, AppSettings.default.temperature)

        var next = service.current
        next.temperature = 1.23
        await service.update(next)

        XCTAssertEqual(service.current.temperature,
                       AppSettings.default.temperature,
                       "current must not advance when the store rejects the save.")
    }

    func testSetKeyPathIsSaveFirst() async {
        let store = FailingSettingsStore(failSaves: true)
        let service = SettingsService(store: store)
        await service.load()

        await service.set(\.haptics, to: false)

        XCTAssertEqual(service.current.haptics,
                       AppSettings.default.haptics,
                       "set(_:to:) should not mutate current when persist fails.")
    }

    func testUpdateCommitsOnSuccessfulSave() async throws {
        let store = InMemoryStore.empty()
        let service = SettingsService(store: store)
        await service.load()

        var next = service.current
        next.temperature = 0.9
        await service.update(next)

        XCTAssertEqual(service.current.temperature, 0.9)
        let persisted = try await store.loadAppSettings()
        XCTAssertEqual(persisted?.temperature, 0.9)
    }
}

// MARK: - Test double
//
// Minimal Store that can be toggled to fail on save, letting us
// exercise SettingsService's save-first semantics without touching
// disk or mocking the whole protocol elsewhere.

private actor FailingSettingsStore: Store {
    private var settings: AppSettings?
    private let failSaves: Bool

    init(failSaves: Bool) {
        self.failSaves = failSaves
    }

    struct Boom: Error {}

    // Only these two methods matter for SettingsService; every other
    // protocol method forwards to a no-op / nil value. Adding new
    // Store requirements later will force a compile error here,
    // which is what we want.

    func loadAppSettings() async throws -> AppSettings? { settings }
    func save(settings: AppSettings) async throws {
        if failSaves { throw Boom() }
        self.settings = settings
    }

    // MARK: Stubs (unused by SettingsService)

    func loadUserProfile() async throws -> UserProfile? { nil }
    func save(userProfile: UserProfile) async throws {}
    func loadAssistantProfile() async throws -> AssistantProfile? { nil }
    func save(assistant: AssistantProfile) async throws {}
    func loadConversations() async throws -> [Conversation] { [] }
    func save(conversation: Conversation) async throws {}
    func delete(conversationID: UUID) async throws {}
    func loadMessages(conversationID: UUID) async throws -> [Message] { [] }
    func save(message: Message) async throws {}
    func deleteMessage(id: UUID, conversationID: UUID) async throws {}
    func clearMessages(conversationID: UUID) async throws {}
    func loadMemoryFacts() async throws -> [MemoryFact] { [] }
    func save(fact: MemoryFact) async throws {}
    func deleteMemoryFact(id: UUID) async throws {}
    func loadMemoryEpisodes() async throws -> [MemoryEpisode] { [] }
    func save(episode: MemoryEpisode) async throws {}
    func deleteMemoryEpisode(id: UUID) async throws {}
    func loadOnboardingState() async throws -> OnboardingState? { nil }
    func save(onboardingState: OnboardingState) async throws {}
}
