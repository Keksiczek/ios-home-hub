import Foundation
import SwiftUI
import UIKit

// MARK: - ConversationServiceError

enum ConversationServiceError: LocalizedError {
    case generationTimeout

    var errorDescription: String? {
        switch self {
        case .generationTimeout:
            return "Generation did not complete within the allowed time. Please try again."
        }
    }
}

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

    /// Per-conversation generation phase, observed by the chat UI so
    /// it can distinguish "reading context" (compute-heavy prefill, no
    /// tokens yet) from "typing" (decode streaming tokens). Without
    /// this signal, long RAG/attachment prefills (5–15 s on iPhone)
    /// look indistinguishable from a frozen app.
    ///
    /// Transitions:
    ///   - `performSend` start  → `.prefill` (entry written when streaming begins)
    ///   - First `.token` event → `.decoding`
    ///   - Stream end / cancel  → entry removed
    @Published private(set) var generationPhase: [UUID: GenerationPhase] = [:]

    /// Most-recent non-fatal warning emitted by the runtime watchdog
    /// (token stall, etc.). UI subscribers can read this to surface a
    /// transient banner ("Model is taking longer than usual…"). Replaced
    /// on every new warning; cleared when the next generation completes
    /// successfully so the banner doesn't linger across turns.
    @Published private(set) var lastRuntimeWarning: RuntimeWarning?

    /// Clears the warning banner. Called by the UI after the user
    /// acknowledges it or after a successful turn completes.
    func acknowledgeRuntimeWarning() {
        lastRuntimeWarning = nil
    }

    enum GenerationPhase: Equatable, Sendable {
        case prefill
        case decoding
    }

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
    /// Keyed by conversationID; set to `true` by the timeout watchdog task
    /// before it calls `cancelStream`. Cleared in `performSend`'s defer block.
    private var timedOutConversations: Set<UUID> = []

    /// LRU access order — most-recently-touched conversation ID is at the
    /// end. Used to evict cold entries from `messagesByConversation` when
    /// the user has cycled through many chats in a single session
    /// (without this cap, a power user with 100+ conversations could
    /// hold 100 × N messages in RAM even though they're only viewing
    /// one at a time — a common path to background-jetsam).
    private var messagesLRU: [UUID] = []
    /// Hard cap on cached conversations' messages. Picked to comfortably
    /// fit on the smallest supported device (6 GB tier) while still
    /// covering the realistic "I have a few chats open" working set.
    /// Eviction drops the OLDEST-accessed entry and the cached summary
    /// for it; the SwiftData store remains the source of truth.
    private static let messagesCacheCap = 12

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
        do {
            conversations = try await store.loadConversations()
        } catch {
            // Disk corruption or migration failure — start fresh in memory
            // but log so users who report "my chats vanished" can be
            // diagnosed from Console.app instead of guessing.
            HHLog.chat.error("loadConversations failed: \(error.localizedDescription, privacy: .public)")
            conversations = []
        }
        // Discard any Task handles left over from before launch (crash or
        // process restart).  The tasks themselves are gone; keeping the
        // dictionary entries would permanently block new sends.
        activeStreams.removeAll()
        streamingConversationIDs.removeAll()
    }

    /// Pure read — SAFE to call from a SwiftUI `body`. Does NOT touch
    /// the LRU; pair it with `noteConversationAccess(_:)` in the
    /// view's `.onAppear` so the cache still tracks active surfaces.
    /// (Mutating private state during view evaluation is the standard
    /// "Modifying state during view update" footgun — SwiftUI doesn't
    /// observe `messagesLRU` directly, but the pattern still risks
    /// re-entrancy if a future refactor publishes it.)
    func messages(in conversationID: UUID) -> [Message] {
        messagesByConversation[conversationID] ?? []
    }

    /// Marks a conversation as recently-viewed for LRU bookkeeping.
    /// Call from `ChatDetailView.onAppear`. Cheap (no @Published
    /// emission) so calling multiple times is harmless.
    func noteConversationAccess(_ conversationID: UUID) {
        touchLRU(conversationID)
        evictColdEntriesIfNeeded()
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
            touchLRU(conversationID)
            evictColdEntriesIfNeeded()
            for i in staleIndexes {
                try? await store.save(message: loaded[i])
            }
        }
    }

    // MARK: - LRU cache management
    //
    // Two-step touch / evict pattern. `touchLRU` is O(n) on the LRU
    // array but n is bounded by `messagesCacheCap`, so it's effectively
    // constant time. Eviction NEVER touches an entry that has an active
    // stream — losing the in-flight assistant message would surface as
    // a UI glitch ("the bubble disappeared!"). All access paths route
    // through these two helpers; the property is otherwise treated as
    // read-only by the rest of the class.

    private func touchLRU(_ id: UUID) {
        if let idx = messagesLRU.firstIndex(of: id) {
            messagesLRU.remove(at: idx)
        }
        messagesLRU.append(id)
    }

    private func evictColdEntriesIfNeeded() {
        while messagesLRU.count > Self.messagesCacheCap {
            // Find the oldest entry that is safe to evict — i.e. has
            // no active stream. Skip any active ones; if every cached
            // entry has an active stream (pathological), we simply
            // tolerate going slightly over the cap until one finishes.
            guard let victimIdx = messagesLRU.firstIndex(where: { activeStreams[$0] == nil }) else {
                break
            }
            let victim = messagesLRU.remove(at: victimIdx)
            messagesByConversation.removeValue(forKey: victim)
            summaryByConversation.removeValue(forKey: victim)
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
        touchLRU(convo.id)
        evictColdEntriesIfNeeded()
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
        // Capture the in-flight stream Task BEFORE the lifecycle teardown
        // clears `activeStreams`. We need the handle to `await` its
        // unwind below — without that wait, the Task's pending
        // `store.save(message: assistantMessage)` could resume AFTER
        // `store.delete(conversationID:)` returns, leaving an orphan
        // message row that the next launch surfaces as a phantom turn.
        // The Task is already cancelled by `endGenerationLifecycle`; we
        // just need to let it reach its `defer` block before deleting
        // anything persistent.
        let pendingStream = activeStreams[id]

        // Single teardown for the four streaming-state slots. After
        // this call the deleted conversation is guaranteed to be
        // absent from every lifecycle dictionary — no orphan windows
        // while the cancelled Task unwinds.
        endGenerationLifecycle(for: id, cancellingTask: true)
        conversations.removeAll { $0.id == id }
        messagesByConversation[id] = nil
        summaryByConversation[id] = nil
        messagesLRU.removeAll { $0 == id }

        // Await the cancelled Task's unwind. `Task<Void, Never>.value`
        // suspends until completion regardless of cancellation outcome
        // (the body's `defer` always runs), so this returns as soon as
        // the stream loop hits its next cancellation checkpoint. Upper
        // bound: a few hundred ms in pathological cases (model still
        // doing the next forward pass); typical case is <50 ms.
        if let pendingStream {
            await pendingStream.value
        }

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

        // Another conversation is streaming — both backends serialise
        // generation per loaded model (MLX via the runtime's `isGenerating`
        // flag, llama.cpp via the C++ context's single-context invariant).
        // Show a cross-conversation hint.
        if !activeStreams.isEmpty {
            showSendFeedback("Model je zaneprázdněn jiným rozhovorem", for: conversationID)
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSend(userInput: trimmed, in: conversationID, attachments: attachments, isWebSearchEnabled: isWebSearchEnabled)
        }
        beginGenerationLifecycle(task, for: conversationID)
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

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSend(userInput: trimmed, in: conversationID, attachments: attachments, isWebSearchEnabled: isWebSearchEnabled)
        }
        beginGenerationLifecycle(task, for: conversationID)
        await task.value
        return .sent
    }

    func cancelStream(in conversationID: UUID) {
        endGenerationLifecycle(for: conversationID, cancellingTask: true)
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

    /// Keeps the most recent `keepLast` messages and drops the rest.
    /// Surfaced in the chat UI as the "Vymazat staré zprávy" action when
    /// the context-fill banner appears (>90% of the context window).
    ///
    /// Persists each delete, blanks the conversation-list preview if the
    /// chat becomes empty, and invalidates the runtime's KV-cache session
    /// so the next turn rebuilds against the trimmed history.
    ///
    /// No-op while a generation is streaming — caller should gate on
    /// `streamingConversationIDs`.
    func trimMessages(in conversationID: UUID, keepLast: Int) async {
        guard keepLast >= 0 else { return }
        guard activeStreams[conversationID] == nil else { return }

        var list = messagesByConversation[conversationID] ?? []
        guard list.count > keepLast else { return }

        let droppedCount = list.count - keepLast
        let droppedIDs = list.prefix(droppedCount).map(\.id)
        list.removeFirst(droppedCount)
        messagesByConversation[conversationID] = list

        for did in droppedIDs {
            try? await store.deleteMessage(id: did, conversationID: conversationID)
        }

        if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[idx].lastMessagePreview = list.last?.content ?? ""
            conversations[idx].updatedAt = .now
            try? await store.save(conversation: conversations[idx])
        }

        // Drop any cached summary — the prefix that produced it is gone.
        summaryByConversation[conversationID] = nil

        // KV cache built against the longer history is no longer valid.
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

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSend(
                userInput: trimmed,
                in: conversationID,
                attachments: attachments,
                skipUserMessage: true
            )
        }
        beginGenerationLifecycle(task, for: conversationID)
    }

    /// Drops the last assistant reply and re-runs generation from the
    /// preceding user message. Works regardless of the dropped message's
    /// status — completed replies, failed turns, and cancelled streams
    /// all funnel through the same path so the chat UI can offer
    /// "Try again" on a failed bubble without a separate code path.
    /// No-op if a stream is already active in this conversation.
    func regenerate(in conversationID: UUID) {
        guard activeStreams[conversationID] == nil else { return }
        var list = messagesByConversation[conversationID] ?? []

        guard let lastAssistantIdx = list.lastIndex(where: { $0.role == .assistant }),
              lastAssistantIdx > 0,
              list[lastAssistantIdx - 1].role == .user else { return }

        let userInput = list[lastAssistantIdx - 1].content
        let attachments = list[lastAssistantIdx - 1].attachments
        let droppedID = list[lastAssistantIdx].id
        list.remove(at: lastAssistantIdx)
        messagesByConversation[conversationID] = list

        // Persist the deletion AND invalidate the KV cache before launching
        // the new stream. Without the disk delete the failed/cancelled
        // bubble would reappear on the next app launch (bootstrap reloads
        // every persisted message). Without the cache invalidation the
        // runtime would happily reuse a prefix that includes tokens from
        // the dropped assistant turn — fine for a clean reply, wrong for
        // a turn the user just disowned.
        Task {
            try? await store.deleteMessage(id: droppedID, conversationID: conversationID)
            await runtime.invalidateSession(for: conversationID)
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSend(
                userInput: userInput,
                in: conversationID,
                attachments: attachments,
                skipUserMessage: true
            )
        }
        beginGenerationLifecycle(task, for: conversationID)
    }

    // MARK: - Generation lifecycle (centralised)
    //
    // The chat surface tracks a streaming turn through four observable
    // slots:
    //   1. `activeStreams[id]`           — the cancellation handle for the Task
    //   2. `streamingConversationIDs`    — bool gate the UI reads for isStreaming
    //   3. `generationPhase[id]`         — prefill/decoding for the UI indicator
    //   4. `timedOutConversations`       — set by the watchdog before cancel
    //
    // **Invariant**: at any quiescent point (i.e. between user-visible
    // operations) all four slots agree — either all populated for the
    // same conversationID, or all clear. The helpers below are the only
    // mutation points so we can't drift between them across cleanup
    // paths (normal completion, error, cancel, watchdog, unload,
    // deleteConversation). If you add a new lifecycle path, route it
    // through these helpers instead of mutating the slots directly.

    /// Registers a freshly-started generation Task and marks the
    /// conversation as streaming + in prefill phase. The phase is set
    /// before the runtime is even called so the chat UI shows
    /// "Čte kontext…" during pre-token work (retrieval, embedding,
    /// prompt assembly) — those phases are also "compute, no tokens
    /// yet" from the user's point of view.
    private func beginGenerationLifecycle(_ task: Task<Void, Never>, for conversationID: UUID) {
        activeStreams[conversationID] = task
        streamingConversationIDs.insert(conversationID)
        generationPhase[conversationID] = .prefill
    }

    /// Promotes the phase on the first observed token. No-op if the
    /// conversation isn't actively streaming (defensive: a late event
    /// after teardown must not re-introduce phase state).
    private func markDecoding(for conversationID: UUID) {
        guard streamingConversationIDs.contains(conversationID) else { return }
        if generationPhase[conversationID] == .prefill {
            generationPhase[conversationID] = .decoding
        }
    }

    /// Clears every lifecycle slot for `conversationID`. The single
    /// teardown point used by `cancelStream`, the `performSend` defer,
    /// `deleteConversation`, and any future lifecycle-ending path.
    ///
    /// - Parameter cancellingTask: When `true`, also cancels the active
    ///   Task (used by user-initiated cancel / delete). When `false` the
    ///   caller has just exited the Task body and only needs the
    ///   bookkeeping cleanup (used by the `defer`).
    private func endGenerationLifecycle(for conversationID: UUID, cancellingTask: Bool) {
        if cancellingTask {
            activeStreams[conversationID]?.cancel()
        }
        activeStreams[conversationID] = nil
        streamingConversationIDs.remove(conversationID)
        generationPhase[conversationID] = nil
    }

    #if DEBUG
    /// Test-only hooks for the lifecycle helpers above. Marked
    /// `#if DEBUG` so they aren't part of the release surface — the
    /// production code path only ever calls the `private` helpers
    /// directly. Use these from the test target to write contract
    /// tests without round-tripping through `send()` + a real Task.
    func _test_beginLifecycle(_ task: Task<Void, Never>, for id: UUID) {
        beginGenerationLifecycle(task, for: id)
    }
    func _test_markDecoding(for id: UUID) {
        markDecoding(for: id)
    }
    func _test_endLifecycle(for id: UUID, cancellingTask: Bool) {
        endGenerationLifecycle(for: id, cancellingTask: cancellingTask)
    }
    /// Read-only probe so tests can assert on `activeStreams` membership
    /// without exposing the dictionary itself.
    func _test_hasActiveStream(for id: UUID) -> Bool {
        activeStreams[id] != nil
    }
    #endif

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

    /// Localised fallback shown to the user when the model produces an
    /// empty response. Honours `settings.language` so a Czech-only string
    /// doesn't surface in an English chat (and vice versa).
    private func emptyResponseFallbackMessage() -> String {
        switch settings.current.language.resolved() {
        case .cs:   return "⚠︎ Model vrátil prázdnou odpověď. Zkuste zprávu přeformulovat."
        case .en:   return "⚠︎ The model returned an empty response. Try rephrasing your message."
        case .auto: return "⚠︎ The model returned an empty response. Try rephrasing your message."
        }
    }

    /// Returns the appropriate stop sequences for the currently loaded model.
    /// These are checked at the text level in addition to the EOS token check
    /// inside the active runtime, providing double-stop protection for models that use
    /// a turn-ending token distinct from their vocabulary EOS.
    private func stopSequences(for model: LocalModel?) -> [String] {
        switch model?.family.lowercased() {
        case "gemma3", "gemma2": return ["<end_of_turn>"]
        case "llama":            return ["<|eot_id|>", "<|end_of_text|>"]
        case "phi":              return ["<|end|>", "<|endoftext|>", "<|im_end|>"]
        case "qwen":             return ["<|im_end|>", "<|endoftext|>"]
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

        // `beginGenerationLifecycle` was called by the caller (`send` /
        // `sendAndWait`) before this Task was scheduled, so by the time
        // we land here the four streaming slots are already populated.
        // This Task is the body that exits via the `defer` below.

        // Timeout watchdog: cancels the stream and marks the message `.failed`
        // if generation hangs beyond `generationTimeoutSeconds`. The watchdog
        // task is cancelled in `defer` whenever generation completes normally,
        // so it never fires on a successful turn.
        let timeoutSeconds = settings.current.generationTimeoutSeconds
        let watchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return // Normal cancellation — generation finished in time.
            }
            guard let self, self.streamingConversationIDs.contains(conversationID) else { return }
            self.timedOutConversations.insert(conversationID)
            self.cancelStream(in: conversationID)
        }

        defer {
            watchdog.cancel()
            timedOutConversations.remove(conversationID)
            Self.endBackgroundTask(bgTaskID)
            // Single teardown for every streaming-state slot. `cancellingTask: false`
            // because we're *inside* the Task body — calling cancel on
            // ourselves at this point would be a no-op anyway, but the
            // signature is explicit so the read is unambiguous.
            endGenerationLifecycle(for: conversationID, cancellingTask: false)
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

        // Summarisation: re-uses any summary that was generated for this
        // conversation in a previous turn. Live summary generation is gated
        // behind `settings.streamingEnabled` and a context-fill heuristic
        // (kept for future re-enable; currently the summarizer runs on the
        // same runtime as the user turn so we avoid the latency cost).
        let summaryText: String? = summaryByConversation[conversationID]?.summary


        // Build prompt context with layered memory.
        let facts = await memory.relevantFacts(for: userInput, limit: 8)
        let episodes = await memory.relevantEpisodes(for: userInput, limit: 3)
        let historyWindow = Array(priorMessages.suffix(20))
        
        // Chunk and filter attachments using embeddings
        var topExcerpts: [String] = []
        if let attachments = attachments, !attachments.isEmpty {
            for attachment in attachments {
                let chunks = DocumentReaderService.chunk(text: attachment.extractedText)
                if chunks.isEmpty {
                    HHLog.kb.notice("attachment yielded no usable chunks — skipping context injection for this attachment")
                    continue
                }
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

        // Web Search processing.
        //
        // `WebSearchService.search` returns a literal Czech "no results"
        // string when the upstream finds nothing — appending that as an
        // excerpt would pollute the L3 context block with prose that
        // looks like retrieved evidence. Filter it out here; the model
        // already has the "no network access / use WebSearch tool"
        // guardrail and can respond without a fake snippet.
        if isWebSearchEnabled {
            do {
                let webSnippet = try await WebSearchService.search(query: userInput)
                let trimmed = webSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty,
                   !trimmed.hasPrefix("Nebyly nalezeny") {
                    topExcerpts.append(trimmed)
                } else {
                    HHLog.kb.notice("web search: no results for query — omitting from context")
                }
            } catch {
                HHLog.kb.error("web search failed: \(error.localizedDescription, privacy: .public) — omitting from context")
            }
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

        // Snapshot activeModel once per turn so every lookup downstream
        // (family → capability profile, stopSequences) sees the same
        // model. The reads were already cheap (MainActor property
        // access) but the snapshot makes the data-flow explicit and
        // means a future async pipeline change can't accidentally
        // re-read after a swap.
        let activeModelSnapshot = runtime.activeModel
        let capabilityProfile = ModelCapabilityProfile.resolve(
            family: activeModelSnapshot?.family ?? ""
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
        let stops = stopSequences(for: activeModelSnapshot)
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
            
            // UX: Subtle haptic to confirm generation has physically started
            // (after embedding, search, and memory retrieval finishes).
            HHHaptics.impact(.light, enabled: settings.current.haptics)

            do {
                // Phase was set to `.prefill` by `beginGenerationLifecycle`
                // at the very start of the turn — that includes retrieval,
                // embedding, prompt assembly, and now the runtime prefill
                // itself. The UI shows "Čte kontext…" through all of it
                // because none of these phases emit tokens.
                let stream = runtime.generate(prompt: runtimePrompt, parameters: parameters)
                // Last wall-clock at which the partial assistant content was
                // persisted. Initialised to "now" so the first heartbeat
                // doesn't fire until 5 s in — short replies skip the write
                // entirely (the .finished path is the authoritative save).
                var lastHeartbeatSave = Date()
                for try await event in stream {
                    // Cooperative cancellation. The user can pull
                    // the cancel button mid-stream OR start a fresh
                    // turn that supersedes this one; in both cases
                    // the surrounding `Task` gets cancelled and we
                    // need to bail before the next token lands so
                    // the UI doesn't keep painting orphan text.
                    // The runtime ALSO checks cancellation, but
                    // races are real — checking here on every event
                    // closes the window between "cancel arrives"
                    // and "runtime emits .finished(.cancelled)".
                    if Task.isCancelled {
                        assistantMessage.status = .cancelled
                        messagesByConversation[conversationID]?[assistantIndex] = assistantMessage
                        try? await store.save(message: assistantMessage)
                        break
                    }
                    switch event {
                    case .token(let piece):
                        // First token marks the prefill→decode transition.
                        // `markDecoding` is idempotent and skips publishing
                        // when the phase is already decoding, so calling it
                        // on every token is safe and cheap.
                        markDecoding(for: conversationID)
                        assistantMessage.content += piece
                        messagesByConversation[conversationID]?[assistantIndex] = assistantMessage

                        // Heartbeat save during long streams: persist partial
                        // content every ~5 s so a jetsam / crash mid-stream
                        // doesn't lose minutes of generated text. The user
                        // sees the partial reply with status `.streaming` on
                        // restart, which `loadMessages` rewrites to `.failed`
                        // (offers retry). Cheap because SwiftData throttles
                        // identical-row writes internally; we still gate on
                        // wall-clock to avoid the overhead in the common
                        // short-reply case (<5 s = zero extra writes).
                        let now = Date()
                        if now.timeIntervalSince(lastHeartbeatSave) >= 5.0 {
                            lastHeartbeatSave = now
                            // Snapshot before the await so the value we
                            // persist is exactly what we showed the user
                            // at this point in time, even if more tokens
                            // arrive while the actor hop completes.
                            let snapshot = assistantMessage
                            Task { [store] in
                                try? await store.save(message: snapshot)
                            }
                        }
                    case .finished(let reason, _):
                        assistantMessage.status = (reason == .cancelled) ? .cancelled : .complete
                        messagesByConversation[conversationID]?[assistantIndex] = assistantMessage
                        try? await store.save(message: assistantMessage)

                        // UX: Soft haptic to signify turn completion
                        if reason == .stop || reason == .length {
                            HHHaptics.impact(.soft, enabled: settings.current.haptics)
                        }

                        // Clear any stall banner now that the turn ended
                        // — keeping it visible across turns would be
                        // misleading once new tokens are flowing.
                        if lastRuntimeWarning != nil {
                            lastRuntimeWarning = nil
                        }
                    case .warning(let warning):
                        // Non-fatal stall signal from the runtime watchdog.
                        // Published for any subscriber (chat banner, etc.)
                        // while keeping the for-await loop running — the
                        // model is still expected to recover and stream
                        // more tokens after a stall.
                        lastRuntimeWarning = warning
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

            // Strip any trailing stop-sequence token from the completed response.
            // These are structural wire-format tokens (<|eot_id|>, <end_of_turn>, etc.)
            // that MLX may not strip on its own when we hit a custom stop sequence.
            // They must never be visible to the user or passed to the tool parser.
            if assistantMessage.status == .complete {
                var content = assistantMessage.content
                for stop in stops where content.hasSuffix(stop) {
                    content = String(content.dropLast(stop.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
                if content != assistantMessage.content {
                    assistantMessage.content = content
                    messagesByConversation[conversationID]?[assistantIndex] = assistantMessage
                }
            }

            // Fallback for empty responses
            if assistantMessage.status == .complete && assistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                assistantMessage.status = .failed
                assistantMessage.content = emptyResponseFallbackMessage()
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

        // Final cancellation reconciliation: distinguish a user-initiated cancel
        // from a timeout. The timeout watchdog inserts the conversationID into
        // `timedOutConversations` before calling `cancelStream`, so we can tell
        // them apart here. Timeout → `.failed` with an explanatory message;
        // user cancel → `.cancelled` (intentional, no error copy needed).
        if Task.isCancelled, assistantMessage.status == .streaming {
            if timedOutConversations.contains(conversationID) {
                assistantMessage.status = .failed
                let timeoutMsg = "⏱ \(ConversationServiceError.generationTimeout.errorDescription ?? "Generation timeout")"
                assistantMessage.content = assistantMessage.content.isEmpty
                    ? timeoutMsg
                    : assistantMessage.content + "\n\n" + timeoutMsg
            } else {
                assistantMessage.status = .cancelled
            }
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
            // Background priority ensures extraction inference never competes
            // with the user-visible assistant stream. MemoryService.consider()
            // respects memoryEnabled + autoExtractMemory settings internally,
            // so no guard is needed here.
            Task.detached(priority: .background) { [memory] in
                await memory.consider(message: msg)
            }
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
