import Foundation

/// In-memory `Store` for previews and tests. Never touches disk.
///
/// Seeded synchronously during init so SwiftUI previews have data
/// the moment `AppContainer.preview()` returns — no Task races.
actor InMemoryStore: Store {
    private var user: UserProfile?
    private var assistant: AssistantProfile?
    private var conversations: [Conversation] = []
    private var messages: [UUID: [Message]] = [:]
    private var facts: [MemoryFact] = []
    private var episodes: [MemoryEpisode] = []
    private var settings: AppSettings?
    private var onboarding: OnboardingState?

    init(seeded: Bool) {
        if seeded {
            self.user = UserProfile(
                id: UUID(),
                displayName: "Alex",
                pronouns: "they/them",
                occupation: "Product designer",
                locale: "en_US",
                interests: ["typography", "long walks", "espresso"],
                workingContext: "Launching a meditation app",
                preferredResponseStyle: .balanced,
                createdAt: .now,
                updatedAt: .now
            )
            self.assistant = AssistantProfile.defaultAssistant
            self.settings = .default
            self.onboarding = OnboardingState(isCompleted: true, currentStep: .finish)

            let convo = Conversation.new(
                assistantID: AssistantProfile.defaultAssistant.id,
                modelID: "llama-3.2-3b-instruct-q4_k_m",
                title: "Getting started"
            )
            self.conversations = [convo]
            self.messages[convo.id] = [
                Message(id: UUID(), conversationID: convo.id, role: .user,
                        content: "Hi! What can you actually do offline?",
                        createdAt: .now.addingTimeInterval(-120),
                        status: .complete, tokenCount: 12),
                Message(id: UUID(), conversationID: convo.id, role: .assistant,
                        content: "I run entirely on this device. I can chat, draft text, summarize, brainstorm, and remember things you let me remember. None of it leaves your iPhone.",
                        createdAt: .now.addingTimeInterval(-110),
                        status: .complete, tokenCount: 38)
            ]

            self.facts = [
                MemoryFact(id: UUID(),
                           content: "Prefers concise replies in the morning",
                           category: .preferences, source: .userManual,
                           confidence: 0.95,
                           createdAt: .now, lastUsedAt: nil,
                           pinned: true, disabled: false),
                MemoryFact(id: UUID(),
                           content: "Designs a meditation app called Stillpoint",
                           category: .projects, source: .onboarding,
                           confidence: 1.0,
                           createdAt: .now, lastUsedAt: nil,
                           pinned: false, disabled: false)
            ]
        }
    }

    static func empty() -> InMemoryStore { InMemoryStore(seeded: false) }
    static func populated() -> InMemoryStore { InMemoryStore(seeded: true) }

    // MARK: - Store

    func loadUserProfile() async throws -> UserProfile? { user }
    func save(userProfile: UserProfile) async throws { user = userProfile }

    func loadAssistantProfile() async throws -> AssistantProfile? { assistant }
    func save(assistant: AssistantProfile) async throws { self.assistant = assistant }

    func loadConversations() async throws -> [Conversation] { conversations }
    func save(conversation: Conversation) async throws {
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
    }
    func delete(conversationID: UUID) async throws {
        conversations.removeAll { $0.id == conversationID }
        messages[conversationID] = nil
    }

    func loadMessages(conversationID: UUID) async throws -> [Message] {
        messages[conversationID] ?? []
    }
    func save(message: Message) async throws {
        var list = messages[message.conversationID] ?? []
        if let idx = list.firstIndex(where: { $0.id == message.id }) {
            list[idx] = message
        } else {
            list.append(message)
        }
        messages[message.conversationID] = list
    }

    func loadMemoryFacts() async throws -> [MemoryFact] { facts }
    func save(fact: MemoryFact) async throws {
        if let idx = facts.firstIndex(where: { $0.id == fact.id }) {
            facts[idx] = fact
        } else {
            facts.append(fact)
        }
    }
    func deleteMemoryFact(id: UUID) async throws {
        facts.removeAll { $0.id == id }
    }

    func loadMemoryEpisodes() async throws -> [MemoryEpisode] { episodes }
    func save(episode: MemoryEpisode) async throws {
        if let idx = episodes.firstIndex(where: { $0.id == episode.id }) {
            episodes[idx] = episode
        } else {
            episodes.append(episode)
        }
    }
    func deleteMemoryEpisode(id: UUID) async throws {
        episodes.removeAll { $0.id == id }
    }

    func loadAppSettings() async throws -> AppSettings? { settings }
    func save(settings: AppSettings) async throws { self.settings = settings }

    func loadOnboardingState() async throws -> OnboardingState? { onboarding }
    func save(onboardingState: OnboardingState) async throws { self.onboarding = onboardingState }
}
