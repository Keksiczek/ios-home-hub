import Foundation

/// Single facade over local persistence.
///
/// Two implementations:
/// - `FileStore`     — production, JSON files in Application Support.
/// - `InMemoryStore` — previews and tests, no disk I/O.
///
/// Designed so a SwiftData/GRDB rewrite later only has to satisfy
/// this protocol; service code never imports anything from the
/// persistence stack directly.
protocol Store: AnyObject, Sendable {
    func loadUserProfile() async throws -> UserProfile?
    func save(userProfile: UserProfile) async throws

    func loadAssistantProfile() async throws -> AssistantProfile?
    func save(assistant: AssistantProfile) async throws

    func loadConversations() async throws -> [Conversation]
    func save(conversation: Conversation) async throws
    func delete(conversationID: UUID) async throws

    func loadMessages(conversationID: UUID) async throws -> [Message]
    func save(message: Message) async throws
    /// Removes a single message from the given conversation. No-op if
    /// the message isn't present.
    func deleteMessage(id: UUID, conversationID: UUID) async throws
    /// Removes every message in the given conversation while keeping
    /// the conversation itself. Used by "Clear conversation".
    func clearMessages(conversationID: UUID) async throws

    func loadMemoryFacts() async throws -> [MemoryFact]
    func save(fact: MemoryFact) async throws
    func deleteMemoryFact(id: UUID) async throws

    func loadMemoryEpisodes() async throws -> [MemoryEpisode]
    func save(episode: MemoryEpisode) async throws
    func deleteMemoryEpisode(id: UUID) async throws

    func loadAppSettings() async throws -> AppSettings?
    func save(settings: AppSettings) async throws

    func loadOnboardingState() async throws -> OnboardingState?
    func save(onboardingState: OnboardingState) async throws
}
