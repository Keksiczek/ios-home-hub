import Foundation
import SwiftUI
import UIKit

/// Orchestrates chat. This is where the runtime, memory, prompt
/// assembly, and persistence meet. UI never calls the runtime
/// directly — it goes through `send(...)`.
@MainActor
final class ConversationService: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var messagesByConversation: [UUID: [Message]] = [:]
    @Published private(set) var streamingConversationIDs: Set<UUID> = []
    /// Inline send-blocked feedback keyed by conversation ID.
    /// Set when the user tries to send while a generation is active;
    /// auto-cleared after 3 seconds. UI observes this to show an
    /// inline hint rather than silently dropping the message.
    @Published private(set) var sendFeedback: [UUID: String] = [:]

    /// True when any conversation is currently streaming.
    var isAnyStreaming: Bool { !streamingConversationIDs.isEmpty }

    private let store: any Store
    private let runtime: RuntimeManager
    private let prompts: PromptAssemblyService
    private let memory: MemoryService
    private let settings: SettingsService
    private let personalization: PersonalizationService
    private let userMemory: UserMemoryStore?
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
        userMemory: UserMemoryStore? = nil,
        summarizer: SummarizationService? = nil,
        embeddingService: EmbeddingService = EmbeddingService()
    ) {
        self.store = store
        self.runtime = runtime
        self.prompts = prompts
        self.memory = memory
        self.settings = settings
        self.personalization = personalization
        self.userMemory = userMemory
        // Default-construct the summarizer when callers (tests/previews)
        // don't supply one. Production goes through `AppContainer` which
        // always injects the shared instance.
        self.summarizer = summarizer ?? SummarizationService(runtime: runtime, prompts: prompts)
        self.embeddingService = embeddingService
    }

    // MARK: - Loading

    func load() async {
        conversations = (try? await store.loadConversations()) ?? []
        // Discard any Task handles left over from before launch (crash or
        // process restart).  The tasks themselves are gone; keeping the
        // dictionary entries would permanently block new sends.
        activeStreams.removeAll()
        streamingConversationIDs.removeAll()
    }

    func messages(in conversationID: UUID) -> [Message] {
        messagesByConversation[conversationID] ?? []
    }

    func loadMessages(for conversationID: UUID) async {
        if var loaded = try? await store.loadMessages(conversationID: conversationID) {
            // A crash while streaming leaves messages with .streaming status on disk.
            // Mark them `.failed` — not `.cancelled` — because the user didn't
            // intentionally stop the stream; the process died. This lets the UI
            // show a retry affordance instead of a benign "cancelled" pill.
            var staleIndexes: [Int] = []
            for i in loaded.indices where loaded[i].status == .streaming {
                loaded[i].status = .failed
                staleIndexes.append(i)
            }
            messagesByConversation[conversationID] = loaded
            for i in staleIndexes {
                try? await store.save(message: loaded[i])
            }
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
        await runtime.invalidateSession(for: id)
        try? await store.delete(conversationID: id)
    }

    // MARK: - Send

    func send(userInput: String, in conversationID: UUID, attachments: [Message.Attachment]? = nil, isWebSearchEnabled: Bool = false) {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || (attachments?.isEmpty == false) else { return }

        // Same conversation already streaming — show inline hint, don't drop silently.
        if activeStreams[conversationID] != nil {
            showSendFeedback("Počkejte na dokončení odpovědi", for: conversationID)
            return
        }

        // Another conversation is streaming — llama.cpp allows only one
        // concurrent generation.  Show a cross-conversation hint.
        if !activeStreams.isEmpty {
            showSendFeedback("Model je zaneprázdněn jiným rozhovorem", for: conversationID)
            return
        }

        activeStreams[conversationID] = Task { [weak self] in
            guard let self else { return }
            await self.performSend(userInput: trimmed, in: conversationID, attachments: attachments, isWebSearchEnabled: isWebSearchEnabled)
        }
    }

    private func showSendFeedback(_ message: String, for conversationID: UUID) {
        sendFeedback[conversationID] = message
        // Snapshot the message so a concurrent tap that overwrites the
        // feedback with a DIFFERENT string doesn't get cleared early by
        // this Task's delayed reset. Only clear if the value hasn't changed.
        let snapshot = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.sendFeedback[conversationID] == snapshot {
                self?.sendFeedback[conversationID] = nil
            }
        }
    }

    /// Result of a `sendAndWait` call — exposed to App Intents / widgets so
    /// Shortcuts.app (or the widget) can show a meaningful message instead of
    /// silently swallowing the send.
    enum SendResult: Equatable {
        case sent
        case emptyInput
        case blockedSameConversation
        case blockedOtherConversation
        case modelNotReady
    }

    /// Odeslání zprávy se synchronním čekáním na výsledek (vhodné pro App Intents a widgety).
    /// Vrací `SendResult`, aby volající mohl zobrazit smysluplnou chybovou hlášku.
    @discardableResult
    func sendAndWait(userInput: String, in conversationID: UUID, attachments: [Message.Attachment]? = nil, isWebSearchEnabled: Bool = false) async -> SendResult {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || (attachments?.isEmpty == false) else { return .emptyInput }
        guard runtime.activeModel != nil else { return .modelNotReady }
        guard activeStreams[conversationID] == nil else { return .blockedSameConversation }
        guard activeStreams.isEmpty else { return .blockedOtherConversation }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSend(userInput: trimmed, in: conversationID, attachments: attachments, isWebSearchEnabled: isWebSearchEnabled)
        }
        activeStreams[conversationID] = task
        await task.value
        return .sent
    }

    func cancelStream(in conversationID: UUID) {
        activeStreams[conversationID]?.cancel()
        activeStreams[conversationID] = nil
        streamingConversationIDs.remove(conversationID)
    }

    /// Removes a single message from the in-memory list and backing store.
    /// No-op if a generation is currently streaming in this conversation —
    /// the caller should gate the UI action on `streamingConversationIDs`.
    func deleteMessage(messageID: UUID, in conversationID: UUID) async {
        guard activeStreams[conversationID] == nil else { return }

        var list = messagesByConversation[conversationID] ?? []
        let before = list.count
        list.removeAll { $0.id == messageID }
        guard list.count != before else { return }

        messagesByConversation[conversationID] = list
        try? await store.deleteMessage(id: messageID, conversationID: conversationID)

        // Keep the conversation list preview in sync with whatever the
        // last remaining message is (or blank it out if the chat is empty).
        if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[idx].lastMessagePreview = list.last?.content ?? ""
            conversations[idx].updatedAt = .now
            try? await store.save(conversation: conversations[idx])
        }

        // Dropping arbitrary messages invalidates any prefix the runtime
        // has cached for this conversation — force a fresh KV-cache build
        // on the next turn so we don't feed the model an inconsistent prefix.
        await runtime.invalidateSession(for: conversationID)
    }

    /// Removes every message in the conversation but leaves the
    /// conversation itself in the list — the user can keep chatting
    /// under the same title.
    func clearMessages(in conversationID: UUID) async {
        guard activeStreams[conversationID] == nil else { return }

        messagesByConversation[conversationID] = []
        try? await store.clearMessages(conversationID: conversationID)
        summaryByConversation[conversationID] = nil

        if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[idx].lastMessagePreview = ""
            conversations[idx].updatedAt = .now
            try? await store.save(conversation: conversations[idx])
        }

        await runtime.invalidateSession(for: conversationID)
    }

    /// Replaces the text of an existing user message and re-runs the
    /// assistant reply. The classic "edit and resend" flow: drop every
    /// message after the edited one, persist the new text, and stream a
    /// fresh assistant turn. No-op if a stream is currently active in
    /// this conversation.
    func editAndResend(messageID: UUID, newText: String, in conversationID: UUID) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeStreams[conversationID] == nil, !trimmed.isEmpty else { return }

        var list = messagesByConversation[conversationID] ?? []
        guard let idx = list.firstIndex(where: { $0.id == messageID }),
              list[idx].role == .user else { return }

        // Snapshot the attachments — the user is editing the text, but
        // they almost certainly still mean the same files / photos.
        let attachments = list[idx].attachments

        // Drop every message that came after the edited one. Persist the
        // deletes so the on-disk transcript stays consistent with the
        // in-memory list.
        let dropped = list.suffix(from: idx + 1).map(\.id)
        list.removeLast(list.count - (idx + 1))
        list[idx].content = trimmed
        list[idx].createdAt = .now

        messagesByConversation[conversationID] = list
        Task {
            for did in dropped {
                try? await store.deleteMessage(id: did, conversationID: conversationID)
            }
            try? await store.save(message: list[idx])
        }

        // Edited prefix invalidates whatever the runtime had cached for
        // this conversation.
        Task { await runtime.invalidateSession(for: conversationID) }

        activeStreams[conversationID] = Task { [weak self] in
            guard let self else { return }
            await self.performSend(
                userInput: trimmed,
                in: conversationID,
                attachments: attachments,
                skipUserMessage: true
            )
        }
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
            guard let self else { return }
            await self.performSend(
                userInput: userInput,
                in: conversationID,
                attachments: attachments,
                skipUserMessage: true
            )
        }
    }

    // MARK: - Internals

    /// Short localised status line shown inside the assistant bubble
    /// while a tool runs. Uses the current `AppLanguage` so the label
    /// doesn't clash with the language rail in the system prompt.
    private func toolRunningLabel(_ skillName: String) -> String {
        let resolved = settings.current.language.resolved()
        switch resolved {
        case .cs: return "Používám nástroj: \(skillName)…"
        case .en, .auto: return "Using tool: \(skillName)…"
        }
    }

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
        isWebSearchEnabled: Bool = false,
        skipUserMessage: Bool = false
    ) async {
        // Ask iOS for extra background runtime so an in-flight generation
        // can finish if the user puts the phone to sleep or switches apps.
        // iOS grants roughly 30 s; when it runs out we stop the stream so
        // the process isn't killed. We always call endBackgroundTask on exit.
        let bgTaskID = Self.beginBackgroundTask { [weak self] in
            self?.cancelStream(in: conversationID)
        }

        streamingConversationIDs.insert(conversationID)
        defer {
            Self.endBackgroundTask(bgTaskID)
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
        // Index of the placeholder in the conversation's message array.
        // Used by the streaming hot path to mutate the message in-place via
        // dictionary subscript (`messagesByConversation[id]?[idx] = …`)
        // instead of copying the array, scanning for the ID, and writing back
        // on every token. Stable for the lifetime of this `performSend` call
        // because nothing else appends to this array while the stream runs.
        let assistantIndex = list.count - 1
        messagesByConversation[conversationID] = list
        try? await store.save(message: assistantMessage)

        // Summarisation trigger: generate a summary of older context once the
        // conversation grows beyond the history window and the estimated context
        // fill crosses 60%. The summary is injected into the system prompt so
        // older turns are never silently dropped. Generated at most once per
        // conversation (stored in summaryByConversation).
        let contextLength = runtime.activeModel?.contextLength ?? 4_096
        let estimatedFill = TokenEstimator.contextFill(
            messages: priorMessages,
            contextLength: contextLength
        )

        var summaryText: String? = summaryByConversation[conversationID]?.summary
        // DISABLED: if priorMessages.count > 20 && estimatedFill > 0.6 && summaryByConversation[conversationID] == nil {
        // DISABLED: // Summarise the older portion; keep the last 10 messages intact in
        // DISABLED: // the history window so recent context stays verbatim.
        // DISABLED: let olderMessages = Array(priorMessages.dropLast(10))
        // DISABLED: if let generated = await summarizer.summarize(messages: olderMessages) {
        // DISABLED: let summary = ConversationSummary(
        // DISABLED: conversationID: conversationID,
        // DISABLED: summary: generated,
        // DISABLED: coversMessageIDs: olderMessages.map(\.id),
        // DISABLED: generatedAt: .now
        // DISABLED: )
        // DISABLED: summaryByConversation[conversationID] = summary
        // DISABLED: summaryText = generated
        // DISABLED: }
        // DISABLED: }
        
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
        
        // Intersect "registered" and "user-enabled" to get the allow-list
        // that drives BOTH the L4 instructions and the runtime dispatch.
        // Doing this once per turn keeps prompt and execution in lockstep:
        // a skill the prompt advertised is always the skill the runtime
        // will actually call — and vice versa.
        let registered = await SkillManager.shared.registeredSkillNames()
        let enabledTools = registered.intersection(settings.current.enabledTools)
        let skillInstructions = await SkillManager.shared
            .buildSystemInstructions(enabled: enabledTools)

        // Overlay the active system-prompt preset onto the persona.
        // Falls back to `AssistantProfile.defaultSystemPrompt` if the
        // active ID no longer resolves to a preset (defensive — the
        // settings model already guarantees this, but keep the fallback
        // so a corrupted settings file can't brick the chat).
        var personaForTurn = personalization.assistantProfile
        let activePreset = settings.current.activeSystemPromptPreset
        let presetPrompt = activePreset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        personaForTurn.systemPromptBase = presetPrompt.isEmpty
            ? AssistantProfile.defaultSystemPrompt
            : activePreset.prompt

        let capabilityProfile = ModelCapabilityProfile.resolve(
            family: runtime.activeModel?.family ?? ""
        )

        let package = PromptContextPackage(
            assistant: personaForTurn,
            user: personalization.userProfile,
            facts: facts,
            episodes: episodes,
            recentMessages: historyWindow,
            userInput: userInput,
            settings: settings.current,
            conversationSummary: summaryText,
            fileExcerpts: topExcerpts,
            skillInstructions: skillInstructions,
            availableTools: enabledTools,
            userMemoryBlock: userMemory?.promptBlock(),
            modelCapabilityProfile: capabilityProfile,
            promptMode: .chat
        )
        let stops = stopSequences(for: runtime.activeModel)
        var parameters = PromptMode.chat.defaultParameters(
            settings: settings.current,
            stopSequences: stops
        )
        parameters.conversationID = conversationID

        let maxLoops = 3
        var currentLoop = 0
        var loopPackage = package

        while currentLoop < maxLoops {
            // Honor user-initiated cancellation between agentic-loop iterations
            // so we don't kick off another inference pass once `cancelStream`
            // has fired. Stream-level cancellation is already handled by the
            // runtime via `.finished(.cancelled)`; this guards the gap between
            // the previous iteration's `.finished` event and the next call to
            // `runtime.generate(...)`.
            if Task.isCancelled { break }
            currentLoop += 1

            let runtimePrompt = prompts.build(from: loopPackage)
            assistantMessage.status = .streaming

            do {
                let stream = runtime.generate(prompt: runtimePrompt, parameters: parameters)
                for try await event in stream {
                    switch event {
                    case .token(let piece):
                        assistantMessage.content += piece
                        messagesByConversation[conversationID]?[assistantIndex] = assistantMessage
                    case .finished(let reason, _):
                        assistantMessage.status = (reason == .cancelled) ? .cancelled : .complete
                        messagesByConversation[conversationID]?[assistantIndex] = assistantMessage
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
                messagesByConversation[conversationID]?[assistantIndex] = assistantMessage
                try? await store.save(message: assistantMessage)
                break
            }

            // Check for Agentic Action
            if assistantMessage.status == .complete {
                if let actionCommand = await SkillManager.shared.parseAction(from: assistantMessage.content) {
                    HHLog.tool.info("loop \(currentLoop) → \(actionCommand.skillName, privacy: .public)")

                    let originalContent = assistantMessage.content
                    assistantMessage.content = originalContent + "\n\n*(\(toolRunningLabel(actionCommand.skillName)))*"
                    messagesByConversation[conversationID]?[assistantIndex] = assistantMessage

                    // Execute via the structured API — timeout + typed failure
                    // reasons so we can decide whether to loop once more or
                    // bail out.
                    let result = await SkillManager.shared.run(actionCommand, enabled: enabledTools)

                    // Seed the context for the next loop so LLM sees what it did and what came back
                    let actionMsg = Message.assistantPlaceholder(in: conversationID)
                    var actionMsgCopy = actionMsg
                    actionMsgCopy.content = originalContent
                    actionMsgCopy.status = .complete

                    let obsMsg = Message.user(
                        "<Observation>\n\(result.observationText)\n</Observation>",
                        in: conversationID
                    )

                    loopPackage.recentMessages.append(actionMsgCopy)
                    loopPackage.recentMessages.append(obsMsg)
                    loopPackage.promptMode = .toolFollowup

                    // Reset message state for the final response stream
                    assistantMessage.content = ""
                    assistantMessage.status = .streaming
                    messagesByConversation[conversationID]?[assistantIndex] = assistantMessage

                    // Non-recoverable failures (unknown / disabled / permission)
                    // break out — forcing another pass would just have the
                    // model re-emit the same call and hit the same wall.
                    if case .error(_, let reason) = result, reason != .timeout && reason != .executionFailed {
                        HHLog.tool.info("loop \(currentLoop) aborting — \(reason.rawValue, privacy: .public)")
                        break
                    }

                    continue
                }
            }

            // If no action was needed, break and finish turn
            break
        }

        // Final cancellation reconciliation: if the user cancelled mid-stream
        // and the message wasn't already marked as `.cancelled` by the runtime
        // (or the loop broke before any event arrived), record it now and
        // persist so the UI doesn't leave a stale `.streaming` placeholder.
        if Task.isCancelled, assistantMessage.status == .streaming {
            assistantMessage.status = .cancelled
            messagesByConversation[conversationID]?[assistantIndex] = assistantMessage
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
            //
            // Use a detached, background-priority Task so the memory-extraction
            // LLM inference pass doesn't compete with the user-visible assistant
            // stream. Without this decoupling, every user message triggers a
            // second full inference run at the same priority as the hot path —
            // doubling perceived latency and battery draw.
                // DISABLED: Task.detached(priority: .background) { [memory] in
                // DISABLED: await memory.consider(message: msg)
                // DISABLED: }
        }

        // Update the home/lock screen widget with latest state.
        WidgetBridge.updateWidget(
            facts: memory.facts,
            conversations: conversations,
            lastAssistantMessage: assistantMessage.content.isEmpty ? nil : String(assistantMessage.content.prefix(200))
        )
    }

    // MARK: - Background task helpers

    /// Registers a background task so iOS grants extra runtime when the app
    /// is backgrounded mid-generation. The `expirationHandler` fires when the
    /// OS is about to kill the task (typically ~30 s after backgrounding);
    /// we use it to cancel the stream gracefully rather than get terminated.
    private static func beginBackgroundTask(expirationHandler: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "HomeHub.inference") {
            // UIKit invokes this on the main thread, but dispatch through an
            // explicit @MainActor Task so the handler can safely touch UI state.
            Task { @MainActor in expirationHandler() }
        }
    }

    private static func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
