import Foundation
import SwiftUI

/// Orchestrates chat. This is where the runtime, memory, prompt
/// assembly, and persistence meet. UI never calls the runtime
/// directly — it goes through `send(...)`.
@MainActor
final class ConversationService: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var messagesByConversation: [UUID: [Message]] = [:]
    @Published private(set) var streamingConversationIDs: Set<UUID> = []

    private let store: any Store
    private let runtime: RuntimeManager
    private let prompts: PromptAssemblyService
    private let memory: MemoryService
    private let settings: SettingsService
    private let personalization: PersonalizationService

    private var activeStreams: [UUID: Task<Void, Never>] = [:]

    init(
        store: any Store,
        runtime: RuntimeManager,
        prompts: PromptAssemblyService,
        memory: MemoryService,
        settings: SettingsService,
        personalization: PersonalizationService
    ) {
        self.store = store
        self.runtime = runtime
        self.prompts = prompts
        self.memory = memory
        self.settings = settings
        self.personalization = personalization
    }

    // MARK: - Loading

    func load() async {
        conversations = (try? await store.loadConversations()) ?? []
    }

    func messages(in conversationID: UUID) -> [Message] {
        messagesByConversation[conversationID] ?? []
    }

    func loadMessages(for conversationID: UUID) async {
        if let loaded = try? await store.loadMessages(conversationID: conversationID) {
            messagesByConversation[conversationID] = loaded
        }
    }

    // MARK: - Conversation lifecycle

    @discardableResult
    func createConversation(title: String = "New chat") async -> Conversation {
        let convo = Conversation.new(
            assistantID: personalization.assistantProfile.id,
            modelID: runtime.activeModel?.id ?? "",
            title: title
        )
        conversations.insert(convo, at: 0)
        messagesByConversation[convo.id] = []
        try? await store.save(conversation: convo)
        return convo
    }

    func rename(conversationID: UUID, to newTitle: String) async {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[idx].title = newTitle
        conversations[idx].updatedAt = .now
        try? await store.save(conversation: conversations[idx])
    }

    func deleteConversation(_ id: UUID) async {
        activeStreams[id]?.cancel()
        activeStreams[id] = nil
        conversations.removeAll { $0.id == id }
        messagesByConversation[id] = nil
        streamingConversationIDs.remove(id)
        try? await store.delete(conversationID: id)
    }

    // MARK: - Send

    func send(userInput: String, in conversationID: UUID) {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard activeStreams[conversationID] == nil else { return }

        activeStreams[conversationID] = Task { [weak self] in
            await self?.performSend(userInput: trimmed, in: conversationID)
        }
    }

    func cancelStream(in conversationID: UUID) {
        activeStreams[conversationID]?.cancel()
        activeStreams[conversationID] = nil
        streamingConversationIDs.remove(conversationID)
    }

    private func performSend(userInput: String, in conversationID: UUID) async {
        streamingConversationIDs.insert(conversationID)
        defer {
            streamingConversationIDs.remove(conversationID)
            activeStreams[conversationID] = nil
        }

        var list = messagesByConversation[conversationID] ?? []

        let userMessage = Message.user(userInput, in: conversationID)
        list.append(userMessage)

        var assistantMessage = Message.assistantPlaceholder(in: conversationID)
        list.append(assistantMessage)
        messagesByConversation[conversationID] = list

        try? await store.save(message: userMessage)
        try? await store.save(message: assistantMessage)

        // Touch conversation preview + timestamp.
        if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[idx].lastMessagePreview = userInput
            conversations[idx].updatedAt = .now
            try? await store.save(conversation: conversations[idx])
        }

        // Build prompt context with layered memory.
        let facts = await memory.relevantFacts(for: userInput, limit: 8)
        let episodes = await memory.relevantEpisodes(for: userInput, limit: 4)
        let historyWindow = Array(list.dropLast().suffix(20))
        let package = PromptContextPackage(
            assistant: personalization.assistantProfile,
            user: personalization.userProfile,
            facts: facts,
            episodes: episodes,
            recentMessages: historyWindow,
            userInput: userInput,
            settings: settings.current
        )
        let runtimePrompt = prompts.build(from: package)
        let parameters = RuntimeParameters(
            maxTokens: settings.current.maxResponseTokens,
            temperature: settings.current.temperature,
            topP: settings.current.topP,
            stopSequences: []
        )

        do {
            let stream = runtime.generate(prompt: runtimePrompt, parameters: parameters)
            for try await event in stream {
                switch event {
                case .token(let piece):
                    assistantMessage.content += piece
                    updateMessage(assistantMessage, in: conversationID)
                case .finished(let reason, _):
                    assistantMessage.status = (reason == .cancelled) ? .cancelled : .complete
                    updateMessage(assistantMessage, in: conversationID)
                    try? await store.save(message: assistantMessage)
                }
            }
        } catch {
            assistantMessage.status = .failed
            if assistantMessage.content.isEmpty {
                assistantMessage.content = "⚠︎ \(error.localizedDescription)"
            } else {
                assistantMessage.content += "\n\n⚠︎ \(error.localizedDescription)"
            }
            updateMessage(assistantMessage, in: conversationID)
            try? await store.save(message: assistantMessage)
        }

        // Fire-and-forget memory consideration on the user turn.
        Task { [memory, userMessage] in
            await memory.consider(message: userMessage)
        }
    }

    private func updateMessage(_ message: Message, in conversationID: UUID) {
        var list = messagesByConversation[conversationID] ?? []
        if let idx = list.firstIndex(where: { $0.id == message.id }) {
            list[idx] = message
            messagesByConversation[conversationID] = list
        }
    }
}
