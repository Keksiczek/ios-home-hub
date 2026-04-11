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
    private let summarizer: SummarizationService
    private let embeddingService: EmbeddingService

    private var activeStreams: [UUID: Task<Void, Never>] = [:]
    private var summaryByConversation: [UUID: ConversationSummary] = [:]

    init(
        store: any Store,
        runtime: RuntimeManager,
        prompts: PromptAssemblyService,
        memory: MemoryService,
        settings: SettingsService,
        personalization: PersonalizationService,
        embeddingService: EmbeddingService = EmbeddingService()
    ) {
        self.store = store
        self.runtime = runtime
        self.prompts = prompts
        self.memory = memory
        self.settings = settings
        self.personalization = personalization
        self.summarizer = SummarizationService(runtime: runtime)
        self.embeddingService = embeddingService
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
        summaryByConversation[id] = nil
        try? await store.delete(conversationID: id)
    }

    // MARK: - Send

    func send(userInput: String, in conversationID: UUID, attachments: [Message.Attachment]? = nil, isWebSearchEnabled: Bool = false) {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || (attachments?.isEmpty == false) else { return }
        guard activeStreams[conversationID] == nil else { return }

        activeStreams[conversationID] = Task { [weak self] in
            await self?.performSend(userInput: trimmed, in: conversationID, attachments: attachments, isWebSearchEnabled: isWebSearchEnabled)
        }
    }

    /// Odeslání zprávy se synchronním čekáním na výsledek (vhodné pro App Intents a widgety)
    func sendAndWait(userInput: String, in conversationID: UUID, attachments: [Message.Attachment]? = nil, isWebSearchEnabled: Bool = false) async {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || (attachments?.isEmpty == false) else { return }
        guard activeStreams[conversationID] == nil else { return }

        let task = Task { [weak self] in
            await self?.performSend(userInput: trimmed, in: conversationID, attachments: attachments, isWebSearchEnabled: isWebSearchEnabled)
        }
        activeStreams[conversationID] = task
        await task.value
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
        let attachments = list[lastAssistantIdx - 1].attachments
        list.remove(at: lastAssistantIdx)
        messagesByConversation[conversationID] = list

        activeStreams[conversationID] = Task { [weak self] in
            await self?.performSend(
                userInput: userInput,
                in: conversationID,
                attachments: attachments,
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
        attachments: [Message.Attachment]? = nil,
        skipUserMessage: Bool = false
    ) async {
        streamingConversationIDs.insert(conversationID)
        defer {
            streamingConversationIDs.remove(conversationID)
            activeStreams[conversationID] = nil
        }

        var list = messagesByConversation[conversationID] ?? []

        // Capture everything that came BEFORE the current user turn.
        // For fresh sends this is the entire existing history.
        // For regeneration the list already ends with the target user message, so drop it.
        // This snapshot is the source of truth for the history window and summarisation;
        // it must NOT include the current user input (that goes into package.userInput).
        let priorMessages = skipUserMessage ? Array(list.dropLast()) : list

        // Only add a new user message for fresh sends, not regeneration.
        let userMessage: Message?
        if !skipUserMessage {
            let msg = Message.user(userInput, in: conversationID, attachments: attachments)
            list.append(msg)
            userMessage = msg
            try? await store.save(message: msg)

            if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
                conversations[idx].lastMessagePreview = userInput.isEmpty ? "📎 \(attachments?.count ?? 0) file(s)" : userInput
                conversations[idx].updatedAt = .now
                try? await store.save(conversation: conversations[idx])
            }
        } else {
            userMessage = list.last(where: { $0.role == .user })
        }

        var assistantMessage = Message.assistantPlaceholder(in: conversationID)
        list.append(assistantMessage)
        messagesByConversation[conversationID] = list
        try? await store.save(message: assistantMessage)

        // Summarisation trigger: generate a summary of older context once the
        // conversation grows beyond the history window and the estimated context
        // fill crosses 60%. The summary is injected into the system prompt so
        // older turns are never silently dropped. Generated at most once per
        // conversation (stored in summaryByConversation).
        let contextLength = runtime.activeModel?.contextLength ?? 4_096
        let totalChars = priorMessages.reduce(0) { $0 + $1.content.count }
        let estimatedFill = Double(totalChars / 4) / Double(contextLength)

        var summaryText: String? = summaryByConversation[conversationID]?.summary
        if priorMessages.count > 20 && estimatedFill > 0.6 && summaryByConversation[conversationID] == nil {
            // Summarise the older portion; keep the last 10 messages intact in
            // the history window so recent context stays verbatim.
            let olderMessages = Array(priorMessages.dropLast(10))
            if let generated = await summarizer.summarize(messages: olderMessages) {
                let summary = ConversationSummary(
                    conversationID: conversationID,
                    summary: generated,
                    coversMessageIDs: olderMessages.map(\.id),
                    generatedAt: .now
                )
                summaryByConversation[conversationID] = summary
                summaryText = generated
            }
        }
        
        // Build prompt context with layered memory.
        let facts = await memory.relevantFacts(for: userInput, limit: 8)
        let episodes = await memory.relevantEpisodes(for: userInput, limit: 4)
        let historyWindow = Array(priorMessages.suffix(20))
        
        // Chunk and filter attachments using embeddings
        var topExcerpts: [String] = []
        if let attachments = attachments, !attachments.isEmpty {
            for attachment in attachments {
                let chunks = DocumentReaderService.chunk(text: attachment.extractedText)
                if chunks.count <= 3 {
                    topExcerpts.append(contentsOf: chunks)
                } else if let scores = await embeddingService.batchSimilarity(query: userInput, candidates: chunks) {
                    let scored = zip(chunks, scores).sorted { $0.1 > $1.1 }
                    let top = scored.prefix(3).map { $0.0 }
                    topExcerpts.append(contentsOf: top)
                } else {
                    topExcerpts.append(contentsOf: chunks.prefix(3))
                }
            }
        }
        
        // Web Search processing
        if isWebSearchEnabled, let webSnippet = try? await WebSearchService.search(query: userInput) {
            topExcerpts.append(webSnippet)
        }
        
        let package = PromptContextPackage(
            assistant: personalization.assistantProfile,
            user: personalization.userProfile,
            facts: facts,
            episodes: episodes,
            recentMessages: historyWindow,
            userInput: userInput,
            settings: settings.current,
            conversationSummary: summaryText,
            fileExcerpts: topExcerpts,
            skillInstructions: SkillManager.shared.buildSystemInstructions()
        )
        let parameters = RuntimeParameters(
            maxTokens: settings.current.maxResponseTokens,
            temperature: settings.current.temperature,
            topP: settings.current.topP,
            stopSequences: stopSequences(for: runtime.activeModel)
        )

        var maxLoops = 3
        var currentLoop = 0
        var loopPackage = package
        
        while currentLoop < maxLoops {
            currentLoop += 1
            
            let runtimePrompt = prompts.build(from: loopPackage)
            assistantMessage.status = .streaming
            
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
                break
            }
            
            // Check for Agentic Action
            if assistantMessage.status == .complete {
                if let actionCommand = await SkillManager.shared.parseAction(from: assistantMessage.content) {
                    // Show temporary UI indicator
                    let originalContent = assistantMessage.content
                    assistantMessage.content = originalContent + "\n\n*(Agent používá skill: \(actionCommand.skillName)...)*"
                    updateMessage(assistantMessage, in: conversationID)
                    
                    // Execute native skill
                    let result = await SkillManager.shared.execute(actionCommand)
                    
                    // Seed the context for the next loop so LLM sees what it did and what came back
                    let actionMsg = Message.assistantPlaceholder(in: conversationID)
                    var actionMsgCopy = actionMsg
                    actionMsgCopy.content = originalContent
                    actionMsgCopy.status = .complete
                    
                    let obsMsg = Message.user("<Observation>\n\(result)\n</Observation>", in: conversationID)
                    
                    loopPackage.recentMessages.append(actionMsgCopy)
                    loopPackage.recentMessages.append(obsMsg)
                    
                    // Reset message state for the final response stream
                    assistantMessage.content = ""
                    assistantMessage.status = .streaming
                    updateMessage(assistantMessage, in: conversationID)
                    
                    continue
                }
            }
            
            // If no action was needed, break and finish turn
            break
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

        // Update the home/lock screen widget with latest state.
        WidgetBridge.updateWidget(
            facts: memory.facts,
            conversations: conversations,
            lastAssistantMessage: assistantMessage.content.isEmpty ? nil : String(assistantMessage.content.prefix(200))
        )
    }

    private func updateMessage(_ message: Message, in conversationID: UUID) {
        var list = messagesByConversation[conversationID] ?? []
        if let idx = list.firstIndex(where: { $0.id == message.id }) {
            list[idx] = message
            messagesByConversation[conversationID] = list
        }
    }
}
