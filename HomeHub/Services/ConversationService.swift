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

    /// Drops the last assistant reply and re-runs generation from the
    /// preceding user message. No-op if a stream is already active.
    func regenerate(in conversationID: UUID) {
        guard activeStreams[conversationID] == nil else { return }
        var list = messagesByConversation[conversationID] ?? []

        guard let lastAssistantIdx = list.lastIndex(where: { $0.role == .assistant }),
              lastAssistantIdx > 0,
              list[lastAssistantIdx - 1].role == .user else { return }

        let userInput = list[lastAssistantIdx - 1].content
        list.remove(at: lastAssistantIdx)
        messagesByConversation[conversationID] = list

        activeStreams[conversationID] = Task { [weak self] in
            await self?.performSend(
                userInput: userInput,
                in: conversationID,
                skipUserMessage: true
            )
        }
    }

    // MARK: - Internals

    /// Returns the appropriate stop sequences for the currently loaded model.
    /// These are checked at the text level in addition to the EOS token check
    /// inside llama.cpp, providing double-stop protection for models that use
    /// a turn-ending token distinct from their vocabulary EOS.
    private func stopSequences(for model: LocalModel?) -> [String] {
        switch model?.family.lowercased() {
        case "gemma3", "gemma2": return ["<end_of_turn>"]
        case "llama":            return ["<|eot_id|>"]
        default:                 return []
        }
    }

    /// - Parameter skipUserMessage: `true` when called from `regenerate()` —
    ///   the user message is already in the list, don't add it again.
    private func performSend(
        userInput: String,
        in conversationID: UUID,
        skipUserMessage: Bool = false
    ) async {
        streamingConversationIDs.insert(conversationID)
        defer {
            streamingConversationIDs.remove(conversationID)
            activeStreams[conversationID] = nil
        }

        var list = messagesByConversation[conversationID] ?? []

        // Only add a new user message for fresh sends, not regeneration.
        let userMessage: Message?
        if !skipUserMessage {
            let msg = Message.user(userInput, in: conversationID)
            list.append(msg)
            userMessage = msg
            try? await store.save(message: msg)

            if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
                conversations[idx].lastMessagePreview = userInput
                conversations[idx].updatedAt = .now
                try? await store.save(conversation: conversations[idx])
            }
        } else {
            userMessage = nil
        }

        var assistantMessage = Message.assistantPlaceholder(in: conversationID)
        list.append(assistantMessage)
        messagesByConversation[conversationID] = list
        try? await store.save(message: assistantMessage)

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
            stopSequences: stopSequences(for: runtime.activeModel)
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

        // Auto-title: rename "New chat" from first user message content.
        if let msg = userMessage {
            let isFirstMessage = list.filter({ $0.role == .user }).count == 1
            if isFirstMessage,
               let idx = conversations.firstIndex(where: { $0.id == conversationID }),
               conversations[idx].title == "New chat" {
                let title = String(userInput.prefix(60))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await rename(conversationID: conversationID, to: title.isEmpty ? "Chat" : title)
            }

            // Fire-and-forget memory consideration on the user turn.
            Task { [memory] in await memory.consider(message: msg) }
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
