import Foundation

/// JSON-on-disk implementation of `Store`.
///
/// v1 Simplification: each entity collection is one JSON file under
/// `~/Library/Application Support/HomeHub/`. Atomic writes, ISO-8601
/// dates. Migration to SwiftData / GRDB is a future task once entity
/// volume justifies it (likely once the user has thousands of
/// messages or memory grows beyond a few hundred facts).
actor FileStore: Store {
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.rootURL = support.appendingPathComponent("HomeHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private func read<T: Decodable>(_ type: T.Type, from file: String) throws -> T? {
        let url = rootURL.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to file: String) throws {
        let url = rootURL.appendingPathComponent(file)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func remove(_ file: String) throws {
        let url = rootURL.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Profiles

    func loadUserProfile() async throws -> UserProfile? {
        try read(UserProfile.self, from: "user.json")
    }

    func save(userProfile: UserProfile) async throws {
        try write(userProfile, to: "user.json")
    }

    func loadAssistantProfile() async throws -> AssistantProfile? {
        try read(AssistantProfile.self, from: "assistant.json")
    }

    func save(assistant: AssistantProfile) async throws {
        try write(assistant, to: "assistant.json")
    }

    // MARK: - Conversations + messages

    func loadConversations() async throws -> [Conversation] {
        (try read([Conversation].self, from: "conversations.json")) ?? []
    }

    func save(conversation: Conversation) async throws {
        var all = (try read([Conversation].self, from: "conversations.json")) ?? []
        if let idx = all.firstIndex(where: { $0.id == conversation.id }) {
            all[idx] = conversation
        } else {
            all.insert(conversation, at: 0)
        }
        try write(all, to: "conversations.json")
    }

    func delete(conversationID: UUID) async throws {
        var all = (try read([Conversation].self, from: "conversations.json")) ?? []
        all.removeAll { $0.id == conversationID }
        try write(all, to: "conversations.json")
        try remove("messages-\(conversationID.uuidString).json")
    }

    func loadMessages(conversationID: UUID) async throws -> [Message] {
        (try read([Message].self, from: "messages-\(conversationID.uuidString).json")) ?? []
    }

    func save(message: Message) async throws {
        let file = "messages-\(message.conversationID.uuidString).json"
        var all = (try read([Message].self, from: file)) ?? []
        if let idx = all.firstIndex(where: { $0.id == message.id }) {
            all[idx] = message
        } else {
            all.append(message)
        }
        try write(all, to: file)
    }

    // MARK: - Memory

    func loadMemoryFacts() async throws -> [MemoryFact] {
        (try read([MemoryFact].self, from: "memory.json")) ?? []
    }

    func save(fact: MemoryFact) async throws {
        var all = (try read([MemoryFact].self, from: "memory.json")) ?? []
        if let idx = all.firstIndex(where: { $0.id == fact.id }) {
            all[idx] = fact
        } else {
            all.append(fact)
        }
        try write(all, to: "memory.json")
    }

    func deleteMemoryFact(id: UUID) async throws {
        var all = (try read([MemoryFact].self, from: "memory.json")) ?? []
        all.removeAll { $0.id == id }
        try write(all, to: "memory.json")
    }

    // MARK: - Episodes

    func loadMemoryEpisodes() async throws -> [MemoryEpisode] {
        (try read([MemoryEpisode].self, from: "episodes.json")) ?? []
    }

    func save(episode: MemoryEpisode) async throws {
        var all = (try read([MemoryEpisode].self, from: "episodes.json")) ?? []
        if let idx = all.firstIndex(where: { $0.id == episode.id }) {
            all[idx] = episode
        } else {
            all.append(episode)
        }
        try write(all, to: "episodes.json")
    }

    func deleteMemoryEpisode(id: UUID) async throws {
        var all = (try read([MemoryEpisode].self, from: "episodes.json")) ?? []
        all.removeAll { $0.id == id }
        try write(all, to: "episodes.json")
    }

    // MARK: - Settings + onboarding

    func loadAppSettings() async throws -> AppSettings? {
        try read(AppSettings.self, from: "settings.json")
    }

    func save(settings: AppSettings) async throws {
        try write(settings, to: "settings.json")
    }

    func loadOnboardingState() async throws -> OnboardingState? {
        try read(OnboardingState.self, from: "onboarding.json")
    }

    func save(onboardingState: OnboardingState) async throws {
        try write(onboardingState, to: "onboarding.json")
    }
}
