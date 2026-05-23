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
    /// Per-conversation semantic recall over truncated message history.
    /// Used inside `performSend` to surface earlier turns the budgeter
    /// would otherwise drop. Reads the shared `embeddingService` LRU,
    /// so no extra disk or memory footprint beyond what memory facts
    /// already pay for.
    private let recall: ConversationRecallService
    /// Optional sink for the post-assembly real-tokenizer ground-truth
    /// count. Lives outside `PromptAssemblyService` because real
    /// tokenization is async and we don't want to colour the builder;
    /// instead the conversation hot path fires a follow-up Task that
    /// posts the real count to this reporter once the runtime's
    /// tokenizer returns. `nil` in tests / previews that don't wire
    /// observable surfaces.
    private let promptBudgetReporter: PromptBudgetReporter?

    /// Wall-clock the most recent `scenePhase == .background` event
    /// fired through the app, supplied by an injected callback so
    /// the service stays decoupled from `AppContainer`. Read by the
    /// stream epilogue in `performSend` to decide whether the
    /// completed turn crossed a background event. `@MainActor`-typed
    /// because the value source (`AppContainer.lastBackgroundedAt`)
    /// is main-actor isolated and `performSend` already runs there.
    private let recentBackgroundTimestamp: @MainActor () -> Date?

    /// Called once when a stream completes successfully after having
    /// crossed a background transition. Wired by `AppContainer` to
    /// increment `backgroundGenerationCompletions`. Optional so
    /// tests / previews that don't care can pass a no-op.
    private let onBackgroundCompletion: @MainActor () -> Void

    private var activeStreams: [UUID: Task<Void, Never>] = [:]
    private var summaryByConversation: [UUID: ConversationSummary] = [:] {
        didSet {
            // Bump `summaryRevision` whenever any conversation's summary
            // is added, replaced, or removed. SwiftUI views observe this
            // through `@Published` and re-read `summary(for:)` to refresh
            // their "X turns condensed" indicator. Without this signal
            // the indicator stayed stale until another `@Published`
            // tick happened (sending a message, switching chats…).
            summaryRevision &+= 1
        }
    }
    /// Monotonic counter incremented every time the summary store
    /// mutates. Public so SwiftUI views can declare a `@Published`
    /// dependency on summary state without exposing the dictionary
    /// itself. Wraps on overflow — view diff is cheap.
    @Published private(set) var summaryRevision: UInt64 = 0

    /// Read-only snapshot of the cached condensed summary for a
    /// conversation, if any. `nil` while the chat is still raw history
    /// (no summarisation has fired yet) or after `clearSummary(for:)`.
    /// Views display the number of turns folded into the summary so the
    /// user understands why earlier messages "disappeared" from the
    /// recent window.
    func summary(for conversationID: UUID) -> ConversationSummary? {
        summaryByConversation[conversationID]
    }
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
        embeddingService: EmbeddingService = EmbeddingService(),
        promptBudgetReporter: PromptBudgetReporter? = nil,
        recentBackgroundTimestamp: @escaping @MainActor () -> Date? = { nil },
        onBackgroundCompletion: @escaping @MainActor () -> Void = {}
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
        self.recall = ConversationRecallService(embeddings: embeddingService)
        self.promptBudgetReporter = promptBudgetReporter
        self.recentBackgroundTimestamp = recentBackgroundTimestamp
        self.onBackgroundCompletion = onBackgroundCompletion
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

    // MARK: - Full-text search

    /// Most recent deep-search results keyed by the lowercased trimmed
    /// query string. Set to `nil` when no search has run or the user
    /// cleared the query. Read by `ChatListView` to merge with the
    /// instant title/preview filter so chats matching only on body
    /// content also appear in the filtered list.
    ///
    /// The cache lives for one query lifetime — entering a different
    /// query clears it before the new scan begins, so stale matches
    /// from a previous query never leak into the list.
    @Published private(set) var lastDeepSearchQuery: String?
    @Published private(set) var lastDeepSearchMatches: Set<UUID> = []
    @Published private(set) var isDeepSearching: Bool = false

    private var deepSearchTask: Task<Void, Never>?

    /// Cancels any pending deep search and clears the published match
    /// set. Call from the UI when the user clears the search field so
    /// stale match highlights aren't carried over into the unfiltered
    /// list.
    func clearDeepSearch() {
        deepSearchTask?.cancel()
        deepSearchTask = nil
        lastDeepSearchQuery = nil
        lastDeepSearchMatches = []
        isDeepSearching = false
    }

    /// Searches inside message bodies across every conversation,
    /// loading from the store for chats not currently in the LRU
    /// cache. Cached results are scanned synchronously; cold
    /// conversations are streamed in batches so the UI sees matches
    /// land progressively rather than blocking on the full sweep.
    ///
    /// Empty / whitespace-only queries short-circuit to `clearDeepSearch`
    /// so the caller can wire this directly to a `searchable` text
    /// binding without guarding for blank input.
    ///
    /// Repeated calls cancel any in-flight scan — typing into a search
    /// field naturally fires this once per keystroke, so de-duping is
    /// the caller's responsibility (debounce on the UI side); we just
    /// make sure two overlapping scans don't double-publish.
    func searchInMessages(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearDeepSearch()
            return
        }
        let needle = trimmed.lowercased()
        deepSearchTask?.cancel()
        lastDeepSearchQuery = needle
        // Seed with whatever is already in cache so the UI gets instant
        // partial results; cold conversations append below.
        var matches: Set<UUID> = []
        for (id, msgs) in messagesByConversation
            where msgs.contains(where: { $0.content.lowercased().contains(needle) }) {
            matches.insert(id)
        }
        lastDeepSearchMatches = matches

        // Snapshot the conversation IDs we still need to scan. Capturing
        // by value keeps the Task isolated from mutations to
        // `conversations` mid-scan.
        let coldIDs = conversations
            .map(\.id)
            .filter { messagesByConversation[$0] == nil }

        guard !coldIDs.isEmpty else {
            isDeepSearching = false
            return
        }

        isDeepSearching = true
        let storeRef = store
        deepSearchTask = Task { [weak self] in
            // Publish in small batches so the list animates as matches
            // come in rather than freezing the user until the full scan
            // completes. Batch size of 8 keeps update frequency under
            // ~30Hz even on the largest realistic chat library.
            var batch: Set<UUID> = []
            var processed = 0
            for id in coldIDs {
                if Task.isCancelled { return }
                let loaded = (try? await storeRef.loadMessages(conversationID: id)) ?? []
                if loaded.contains(where: { $0.content.lowercased().contains(needle) }) {
                    batch.insert(id)
                }
                processed += 1
                if batch.count >= 8 || processed == coldIDs.count {
                    let flushed = batch
                    batch.removeAll(keepingCapacity: true)
                    await MainActor.run {
                        guard let self else { return }
                        // Drop late results if the user already moved
                        // on to a different query.
                        guard self.lastDeepSearchQuery == needle else { return }
                        self.lastDeepSearchMatches.formUnion(flushed)
                    }
                }
            }
            await MainActor.run {
                guard let self else { return }
                guard self.lastDeepSearchQuery == needle else { return }
                self.isDeepSearching = false
            }
        }
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
            // Pre-warm the recall embedding cache so the *first* send
            // after opening a conversation doesn't pay the full
            // batch-embed cost (~50-200ms on iPhone). The warm-up is
            // fire-and-forget and bounded by EmbeddingService's LRU;
            // a tap-and-immediately-close interaction wastes at most
            // a few cached vectors. Skip when memory is disabled —
            // the recall pipeline won't fire anyway, and the warm-up
            // would just bloat the embedding cache.
            if settings.current.memoryEnabled {
                recall.warmUp(conversationID: conversationID, messages: loaded)
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

    /// Sets the pinned flag on a conversation. Pinned conversations are
    /// rendered in their own section at the top of `ChatListView` so
    /// frequently-used threads don't drift down the list as new chats
    /// arrive. Idempotent; no-op when the flag already matches.
    ///
    /// Intentionally does not bump `updatedAt` — pinning is a UI
    /// affordance, not a content change, and using `updatedAt` for
    /// sort would mean pinning silently jumps the chat ahead of newer
    /// activity in the un-pinned section's secondary sort.
    func setPinned(_ pinned: Bool, conversationID: UUID) async {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard conversations[idx].pinned != pinned else { return }
        conversations[idx].pinned = pinned
        try? await store.save(conversation: conversations[idx])
    }

    /// Sets the archived flag on a conversation. Archived conversations
    /// are hidden from the default chat list view but kept on disk so
    /// the user can restore them later. Surfacing archived chats is
    /// the UI's responsibility (a dedicated "Archived" section / toggle).
    func setArchived(_ archived: Bool, conversationID: UUID) async {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard conversations[idx].archived != archived else { return }
        conversations[idx].archived = archived
        // Archiving an unread pinned chat is contradictory — the user
        // is moving it out of the active set, so drop the pin too.
        if archived { conversations[idx].pinned = false }
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
        // Also tear down ancillary background tasks tied to this
        // conversation. Without this, a prefetch or summarization
        // launched moments before delete keeps running with no
        // observer — wastes CPU + tokenizer work, and the write-back
        // dictionaries leak entries until app teardown.
        prefetchTasks[id]?.cancel()
        prefetchTasks[id] = nil
        summarizationTasks[id]?.cancel()
        summarizationTasks[id] = nil
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
        // Persistent recall index lives in a side-file under
        // Documents — strip it now so deleted conversations don't
        // leave embedding-vector orphans accumulating on disk.
        recall.deleteIndex(for: id)
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
    /// Toggles the bookmark flag on a single message and persists the
    /// change. Bookmarking is a pure UI affordance — it doesn't touch
    /// the runtime, the KV-cache session, or the conversation's
    /// `updatedAt`, so users can bookmark mid-stream without
    /// destabilising anything downstream.
    func toggleBookmark(messageID: UUID, in conversationID: UUID) async {
        var list = messagesByConversation[conversationID] ?? []
        guard let idx = list.firstIndex(where: { $0.id == messageID }) else { return }
        let newValue = !list[idx].isBookmarked
        // Store `nil` when clearing so the persisted JSON stays minimal
        // and older readers (without the field) don't see a redundant
        // `false` they have to ignore.
        list[idx].bookmarked = newValue ? true : nil
        messagesByConversation[conversationID] = list
        try? await store.save(message: list[idx])
    }

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
    /// Stop sequences passed to the runtime. Includes both end-of-turn
    /// markers AND tool-envelope close tags — the latter so weaker
    /// models stop immediately after finishing the tool call instead
    /// of continuing into hallucinated prose.
    private func stopSequences(for model: LocalModel?) -> [String] {
        familyEndOfTurnStops(for: model) + Self.universalToolStops
    }

    /// Per-family end-of-turn markers ONLY. Used both as runtime stops
    /// and as the post-stream strip set — these are structural turn
    /// boundaries we don't want to leak into the user-facing bubble.
    ///
    /// Gemma 3n shares Gemma's surface envelope (`<end_of_turn>`); the
    /// previous switch fell through to `default` for "gemma3n" and the
    /// model kept generating past its own turn marker.
    private func familyEndOfTurnStops(for model: LocalModel?) -> [String] {
        switch model?.family.lowercased() {
        case "gemma3n", "gemma3", "gemma2", "gemma":
            return ["<end_of_turn>"]
        case "llama":   return ["<|eot_id|>", "<|end_of_text|>"]
        case "phi":     return ["<|end|>", "<|endoftext|>", "<|im_end|>"]
        case "qwen":    return ["<|im_end|>", "<|endoftext|>"]
        case "mistral": return ["</s>"]
        default:        return []
        }
    }

    /// Tool-envelope closes recognised across every family. Used ONLY
    /// as runtime stops — we deliberately do NOT strip them from the
    /// completed content because `SkillManager.parseAction` needs the
    /// closing tag to delimit the JSON payload.
    private static let universalToolStops: [String] = [
        "</tool_call>",
        "</function_call>",
        "[/TOOL_CALLS]"
    ]

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

        // Snapshot the perform-start wall-clock so the epilogue can
        // ask "did the most-recent background event happen *after*
        // this send started?". If yes, the generation ran across a
        // background transition and we credit it to the
        // background-completion counter (useful telemetry for
        // verifying the iOS background-task assertion really buys us
        // the 30s the entitlement promises).
        let sendStartedAt = Date()

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
            // Background-completion detection: if the most recent
            // app-background event happened AFTER this performSend
            // started, the generation ran across a background
            // transition. We notify the container only when the
            // stream finished cleanly (i.e. the in-memory message
            // landed in `.complete` state) — a cancelled or failed
            // stream isn't a "background success".
            if let bgAt = recentBackgroundTimestamp(),
               bgAt > sendStartedAt,
               let lastMsg = messagesByConversation[conversationID]?.last,
               lastMsg.status == .complete {
                onBackgroundCompletion()
                HHLog.chat.info("background completion: \(conversationID, privacy: .public) finished after crossing background event")
            }
            // Single teardown for every streaming-state slot. `cancellingTask: false`
            // because we're *inside* the Task body — calling cancel on
            // ourselves at this point would be a no-op anyway, but the
            // signature is explicit so the read is unambiguous.
            endGenerationLifecycle(for: conversationID, cancellingTask: false)
            // Fire-and-forget: when this turn finished with a healthy
            // history that's getting close to the budget, condense the
            // older half into a single paragraph. The next turn picks
            // up the summary via `summaryByConversation[id]` and uses
            // it as `conversationSummary` on `PromptContextPackage`,
            // so the model never sees old turns vanish — they shrink
            // into a one-paragraph recap instead.
            //
            // Runs on the MainActor (RuntimeManager is MainActor-only)
            // but `Task` doesn't await — the user's response is
            // already delivered by the time this fires.
            Task { [weak self] in
                await self?.maybeSummarizeOlderHalf(in: conversationID)
            }
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
        // Adaptive retrieval limits: a short "ok" or "thanks" doesn't
        // need 8 facts injected — that's just context bloat that the
        // model has to read through. A long "remind me about everything
        // we discussed re: the auth flow yesterday" deserves a deeper
        // pull. Sizing by user-input length is a cheap proxy that
        // doesn't need a separate classifier; the user typing more is
        // a strong signal they expect the model to use more grounding.
        let (factLimit, episodeLimit) = Self.adaptiveRetrievalLimits(for: userInput)
        let facts = await memory.relevantFacts(for: userInput, limit: factLimit)
        let episodes = await memory.relevantEpisodes(for: userInput, limit: episodeLimit)
        // Removed the historic `suffix(20)` cap. That fence was a
        // pre-budgeter safety net from before `PromptTokenBudgeter`
        // existed; with the budgeter in place it just silently throws
        // away history that the model could still see. On a 4096-token
        // context, 40 short messages comfortably fit — the cap was
        // dropping them anyway.
        //
        // The budgeter walks newest-first and stops at the per-family
        // `safeHistoryTokenBudget`, so the cost of passing the full
        // list is O(kept_messages), not O(all_messages). Long
        // conversations stay performant.
        //
        // Older messages that the budgeter does trim are recovered via
        // two paths added in this batch:
        //   1. `conversationSummary` — auto-generated when the budget
        //      gets tight, injected as the L0.5 system block.
        //   2. `conversationRecall` — semantic retrieval over the
        //      *truncated* messages; relevant earlier turns ride along
        //      as L2' even after the budgeter drops them.
        let historyWindow = priorMessages
        
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
            family: activeModelSnapshot?.family ?? "",
            parameterCount: activeModelSnapshot?.parameterCount,
            contextLength: activeModelSnapshot?.contextLength
        )

        // Semantic recall over the *truncated* tail of message history.
        //
        // We only ask the recall service to look at messages older
        // than the live window the budgeter will produce — anything
        // newer is already going into `recentMessages` verbatim.
        // Calling `trimHistory` here is a cheap O(kept) walk; we'd do
        // it inside `PromptAssemblyService.build` anyway, so doing it
        // ahead just lets us identify which IDs we already have in
        // the prompt.
        let budgeter = PromptTokenBudgeter(profile: capabilityProfile)
        let trimResult = budgeter.trimHistory(historyWindow)
        let keptIDs = Set(trimResult.kept.map(\.id))
        // Recall is limited to 3 snippets — more would dilute the
        // L2' block and starve other layers on small context windows.
        // Per-conversation embedding lookup is bounded by the
        // EmbeddingService LRU cap (separate from MemoryService).
        // Tightened `minSimilarity` from the recall service's default
        // 0.35 (loosely related) to 0.5 (topical). The lower threshold
        // pulled in marginal matches that confused weak models —
        // observed in the field as Gemma 3n quoting fragments of
        // unrelated past turns instead of answering the current one.
        // Strong models tolerate noise but don't benefit from it.
        let semanticRecall: [Message] = settings.current.memoryEnabled
            ? await recall.recall(
                query: userInput,
                from: historyWindow,
                excluding: keptIDs,
                limit: 3,
                minSimilarity: 0.5
            )
            : []
        // Top up the recall block with intrinsically-important dropped
        // messages — declarations, code fences, numeric facts — that
        // didn't make the semantic cut. The model often needs these
        // for follow-up questions that aren't directly about them
        // ("I'm vegetarian" must survive even if the current turn is
        // about TV shows). Cap the combined recall at 5 entries; any
        // more starts pushing other layers off the budget.
        let recallSlotsRemaining = max(0, 5 - semanticRecall.count)
        let semanticIDs = Set(semanticRecall.map(\.id))
        let importantTopUp: [Message] = settings.current.memoryEnabled && recallSlotsRemaining > 0
            ? MessageImportance.topImportant(
                from: historyWindow,
                excluding: keptIDs.union(semanticIDs),
                limit: recallSlotsRemaining
            )
            : []
        // Concatenate in conversation order so the prompt reads
        // chronologically. We dedupe via ID set as a defensive belt
        // (the `excluding:` filter on `topImportant` already covers it).
        let combinedIDs = Set(semanticRecall.map(\.id))
        let recalledMessages = (semanticRecall + importantTopUp.filter { !combinedIDs.contains($0.id) })
            .sorted { $0.createdAt < $1.createdAt }
        let recalledText = recalledMessages.map { msg in
            let speaker = msg.role == .user ? "Uživatel" : "Asistent"
            return "[\(speaker)] \(msg.content)"
        }

        let package = PromptContextPackage(
            assistant: personaForTurn,
            user: personalization.userProfile,
            facts: facts,
            episodes: episodes,
            recentMessages: historyWindow,
            userInput: userInput,
            settings: settings.current,
            conversationSummary: summaryText,
            conversationRecall: recalledText,
            fileExcerpts: topExcerpts,
            skillInstructions: skillInstructions,
            availableTools: enabledTools,
            userMemoryBlock: userMemory?.promptBlock(),
            modelCapabilityProfile: capabilityProfile,
            promptMode: .chat
        )
        let stops = stopSequences(for: activeModelSnapshot)
        // `parameters` is re-picked at the top of every agentic-loop
        // iteration (see the loop body) so the chat → toolFollowup
        // mode transition gets the right sampling profile each time.
        // Declared here just to extend its scope to the loop.
        // Sampling defaults snap to the family's recommended values
        // when the user is on the factory baseline — without this,
        // every model got the cross-family default temp 0.7 which is
        // wrong for Gemma 3n (causes language drift) and wrong for
        // Qwen (over-permissive).
        var parameters = RuntimeParameters(
            maxTokens: settings.current.maxResponseTokens,
            temperature: 0.7,
            topP: 0.9,
            stopSequences: stops
        )
        parameters.conversationID = conversationID

        // Agentic tool loop ceiling. Loops 1…(maxLoops-1) may emit a tool
        // call; the FINAL allowed loop is a forced synthesis pass — we
        // don't parse it for another action, so the model always gets one
        // turn to turn its observations into a real answer. With
        // maxLoops = 4 that's up to 3 tool calls followed by a guaranteed
        // textual reply.
        //
        // This also fixes a latent bug: previously, if the model emitted a
        // tool call on the last permitted loop, the code reset the assistant
        // content to "" for a follow-up stream that the `while` condition
        // then prevented from running — leaving the user with an empty,
        // permanently-`.streaming` bubble.
        let maxLoops = 4
        var currentLoop = 0
        var loopPackage = package

        // Dead-end detection state for the agentic loop. Two consecutive
        // observations that look empty / "no results" suggest the data
        // source can't answer the user's question — keep looping in that
        // state and the model just chains identical tool calls until the
        // hard ceiling at `maxLoops`. Track the run-length of empty
        // observations and force the next iteration into synthesis mode
        // (`isFinalAllowedLoop == true`) once it hits 2.
        var consecutiveEmptyObservations = 0
        var forceSynthesisNextLoop = false

        // Session-duration budget for the agentic loop. The outer
        // `watchdog` task (line ~945) already enforces a hard cancel at
        // `generationTimeoutSeconds` (default 120 s) for the whole
        // performSend, but that path leaves the message in a `.failed`
        // / `.cancelled` state with a terse "⏱ Generation timeout"
        // banner. This budget is SOFTER: at iteration boundaries we
        // check elapsed time and, if it's past `loopBudgetSeconds`,
        // we flip the next iteration to synthesis mode so the model
        // gets one bounded pass to wrap up with whatever context it
        // already has. Catches the "model burned 90 s on three
        // identical tool calls and still has 30 s of pre-watchdog
        // headroom" case, which would otherwise eat into the user's
        // perceived latency budget without producing an answer.
        //
        // Budget is intentionally ~75 % of the hard timeout so the
        // synthesis pass itself has room to finish before the hard
        // watchdog fires.
        let loopBudgetSeconds: TimeInterval = max(
            30,
            TimeInterval(settings.current.generationTimeoutSeconds) * 0.75
        )
        let loopStartedAt = Date()

        while currentLoop < maxLoops {
            // Honor user-initiated cancellation between agentic-loop iterations
            // so we don't kick off another inference pass once `cancelStream`
            // has fired. Stream-level cancellation is already handled by the
            // runtime via `.finished(.cancelled)`; this guards the gap between
            // the previous iteration's `.finished` event and the next call to
            // `runtime.generate(...)`.
            if Task.isCancelled { break }
            currentLoop += 1

            // Soft session-budget check at the iteration boundary.
            // Past the budget we still allow this iteration to RUN
            // (so the model gets its synthesis pass) but mark it as
            // final so the action parser at the bottom of the loop
            // body refuses to issue another tool call. Logged at
            // `notice` because hitting this regularly is a signal
            // that the user is asking the model questions whose
            // tool-loops don't fit the configured budget.
            let elapsed = Date().timeIntervalSince(loopStartedAt)
            if elapsed > loopBudgetSeconds && !forceSynthesisNextLoop {
                HHLog.tool.notice("loop \(currentLoop) → forcing synthesis: session budget \(Int(loopBudgetSeconds), privacy: .public)s exceeded (elapsed=\(Int(elapsed), privacy: .public)s)")
                forceSynthesisNextLoop = true
            }
            let isFinalAllowedLoop = (currentLoop == maxLoops) || forceSynthesisNextLoop

            // Re-pick sampling params for the current loop's mode. The
            // first iteration is `.chat`; subsequent iterations after a
            // tool execution are `.toolFollowup` which forces near-
            // deterministic sampling (no creative drift when the model
            // is just rendering an observation).
            parameters = loopPackage.promptMode.defaultParameters(
                settings: settings.current,
                profile: capabilityProfile,
                stopSequences: stops
            )
            parameters.conversationID = conversationID

            let runtimePrompt = prompts.build(from: loopPackage)
            assistantMessage.status = .streaming

            // Ground-truth tokenizer count for the assembled prompt.
            // Fire-and-forget — the budget report has already been
            // published by `prompts.build`; we just enrich it with the
            // real number once the tokenizer hop returns. Doing this
            // here (not inside `PromptAssemblyService`) avoids making
            // the synchronous builder async and keeps the report
            // available *immediately* for any caller that doesn't
            // need ground truth.
            let promptForCounting = runtimePrompt.systemPrompt
                + runtimePrompt.messages.map(\.content).joined(separator: "\n")
            Task { [weak self] in
                guard let self,
                      let real = await self.runtime.realTokenCount(of: promptForCounting) else {
                    return
                }
                self.promptBudgetReporter?.recordRealTokenCount(real)
            }

            // Dynamic maxTokens cap — clamp the configured ceiling to the
            // actual remaining context window so a long prompt + a
            // generous `maxResponseTokens` slider can't bust the model's
            // hard context limit mid-stream. Previously the runtime would
            // truncate the reply silently (small-context models like Llama
            // 3.2 3B with 2 048-token context were the prime victims —
            // a 1 800-token prompt + 1 024 requested tokens = guaranteed
            // mid-sentence cutoff).
            //
            // Heuristic vs ground truth: we use the budgeter (heuristic
            // estimator + family overhead) instead of waiting for the
            // async `realTokenCount` hop above. The heuristic tends to
            // OVER-estimate Latin-script prompts by ~15 %, which is the
            // right direction for a safety cap — we'd rather leave a few
            // tokens on the table than overflow. The safety margin
            // covers chat-template wrapper tokens (eot_id, im_end, etc.)
            // that the heuristic doesn't account for.
            if let contextLength = activeModelSnapshot?.contextLength {
                let promptEstimate = budgeter.tokens(in: promptForCounting)
                let safetyMargin = 64
                let remaining = max(64, contextLength - promptEstimate - safetyMargin)
                if parameters.maxTokens > remaining {
                    HHLog.runtime.notice("Dynamic maxTokens cap: \(parameters.maxTokens, privacy: .public) → \(remaining, privacy: .public) (ctx=\(contextLength, privacy: .public) prompt≈\(promptEstimate, privacy: .public))")
                    parameters.maxTokens = remaining
                }
            }

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

            // Strip any trailing end-of-turn marker from the completed
            // response. Only the per-family EOT tokens get stripped —
            // we deliberately leave tool-envelope closes (`</tool_call>`,
            // `</function_call>`, `[/TOOL_CALLS]`) intact because the
            // tool parser needs the closing tag to delimit the payload.
            if assistantMessage.status == .complete {
                let familyStops = familyEndOfTurnStops(for: activeModelSnapshot)
                var content = assistantMessage.content
                for stop in familyStops where content.hasSuffix(stop) {
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

            // Check for Agentic Action. Skipped on the final allowed loop
            // — that pass is reserved for synthesis, so we keep whatever
            // text the model produced rather than resetting it for a
            // follow-up stream that would never run.
            if assistantMessage.status == .complete && !isFinalAllowedLoop {
                if let actionCommand = await SkillManager.shared.parseAction(from: assistantMessage.content) {
                    HHLog.tool.info("loop \(currentLoop) → \(actionCommand.skillName, privacy: .public)")

                    let originalContent = assistantMessage.content
                    assistantMessage.content = originalContent + "\n\n*(\(toolRunningLabel(actionCommand.skillName)))*"
                    messagesByConversation[conversationID]?[assistantIndex] = assistantMessage

                    // Execute via the structured API — timeout + typed failure
                    // reasons so we can decide whether to loop once more or
                    // bail out.
                    let result = await SkillManager.shared.run(actionCommand, enabled: enabledTools)

                    // Dead-end detection: an observation that looks empty
                    // (literally empty, or a "no results" marker from the
                    // engine) two iterations in a row tells us the data
                    // source can't help — schedule the next loop to be
                    // the final synthesis pass so the model gives a
                    // graceful "I couldn't find that" answer instead of
                    // chaining identical tool calls until the ceiling.
                    let obsLower = result.observationText.lowercased()
                    let obsLooksEmpty = result.observationText.isEmpty
                        || obsLower.contains("no results")
                        || obsLower.contains("not found")
                        || obsLower.contains("nebyly nalezeny")
                        || obsLower.contains("nenalezeno")
                        || obsLower.contains("žádné výsledky")
                        || obsLower.contains("zadne vysledky")    // Czech keyboard without diacritics
                        || obsLower.contains("nepodařilo se")
                        || obsLower.contains("error: empty")
                    if obsLooksEmpty {
                        consecutiveEmptyObservations += 1
                        if consecutiveEmptyObservations >= 2 {
                            HHLog.tool.notice("loop \(currentLoop) → forcing synthesis next: 2 consecutive empty observations from \(actionCommand.skillName, privacy: .public)")
                            forceSynthesisNextLoop = true
                        }
                    } else {
                        consecutiveEmptyObservations = 0
                    }

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

        // Defensive finalize: if we left the agentic loop with the
        // assistant still `.streaming` and empty (no token ever landed —
        // e.g. the model only ever emitted tool envelopes), surface a
        // graceful fallback instead of an empty bubble that spins forever.
        if assistantMessage.status == .streaming,
           assistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Task.isCancelled {
            assistantMessage.status = .failed
            assistantMessage.content = emptyResponseFallbackMessage()
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

    // MARK: - Auto-summarization

    /// Auto-condense the older half of the conversation when the budget
    /// is getting tight. Wired into the `performSend` defer block so it
    /// runs after the user already has their response — no UX latency.
    ///
    /// **When it fires.** Only when *all four* conditions hold:
    ///   1. A model is loaded (summarizer needs the runtime).
    ///   2. The conversation has ≥ `minMessagesForSummary` messages —
    ///      short chats don't need a summary, the full history fits.
    ///   3. Estimated history token count > 70 % of the model family's
    ///      `safeHistoryTokenBudget`. Below that the budgeter wouldn't
    ///      trim anything so the summary would be wasted work.
    ///   4. The existing cached summary (if any) doesn't already cover
    ///      the older-half slice — avoids re-summarizing the same range
    ///      every turn.
    ///
    /// **What it does.** Splits the messages roughly in half, takes the
    /// older slice (oldest → midpoint), runs `SummarizationService` to
    /// produce a one-paragraph recap, and stores it in
    /// `summaryByConversation[id]`. The next call to `performSend` reads
    /// the summary into `PromptContextPackage.conversationSummary`,
    /// which `PromptAssemblyService` injects as the "Earlier in this
    /// conversation" block of the system prompt.
    ///
    /// **Hierarchical re-condense.** If the freshly-generated summary is
    /// itself larger than `summaryRecondenseTokenThreshold`, we feed it
    /// back through `summarizer.summarize` once more with a single
    /// pseudo-message. Long conversations (50+ turns) generate summaries
    /// that grow proportionally; without this pass the L0.5 block
    /// would eventually eat the entire budget. One re-condense pass is
    /// enough — empirically the second pass converges to a tight
    /// paragraph, and recursing further hits diminishing returns vs.
    /// the per-pass inference latency.
    ///
    /// **Concurrency.** A single in-flight summarization per conversation
    /// is tracked via `summarizationTasks` — a second call while the
    /// first is running is a no-op, preventing two `runtime.generate(...)`
    /// streams from racing on the same MLX context.
    private func maybeSummarizeOlderHalf(in conversationID: UUID) async {
        guard runtime.activeModel != nil,
              summarizationTasks[conversationID] == nil else { return }

        let messages = messagesByConversation[conversationID] ?? []
        guard messages.count >= Self.minMessagesForSummary else { return }

        let profile = ModelCapabilityProfile.resolve(
            family: runtime.activeModel?.family ?? "",
            parameterCount: runtime.activeModel?.parameterCount,
            contextLength: runtime.activeModel?.contextLength
        )
        // Use the NSCache-backed `TokenEstimator.cachedTokens(in:)`
        // path here instead of looping `budgeter.tokensForMessage` —
        // on a 50-message conversation the cached path avoids
        // re-scanning ~10 000 Unicode scalars on every `send`. Add the
        // per-message chat-template overhead separately since the
        // cached helper counts raw content only.
        let budgeter = PromptTokenBudgeter(profile: profile)
        let estimatedTokens = TokenEstimator.cachedTokens(in: messages)
            + messages.count * profile.messageTokenOverhead
        // Dynamic summarization trigger.
        //
        // Linearly interpolate between **45% (very tight budgets)** and
        // **75% (very generous budgets)** based on `safeHistoryTokenBudget`:
        // a 400-token budget on a tight-memory iPhone fires at 180
        // tokens; a 2800-token budget on a generous-tier device only
        // fires at 2100. Weak instruction-followers shift the curve
        // ~10 points earlier — they degrade quality faster as raw
        // history grows. No more binary 0.55 / 0.7 switch.
        //
        // The curve avoids the previous "weak == fixed 55%" foot-gun
        // where an iPad Pro running Gemma 3n with a 3200-token budget
        // would summarise prematurely at 1760 tokens even though the
        // device had headroom for the full 2400-token window.
        let triggerFraction = Self.summarizationTriggerFraction(
            budget: profile.safeHistoryTokenBudget,
            isWeak: profile.isWeakInstructionFollower
        )
        let threshold = Int(Double(profile.safeHistoryTokenBudget) * triggerFraction)
        guard estimatedTokens > threshold else { return }

        // Slice: older half is messages[0..<midpoint]. The newer half
        // stays as-is in the live history so the model has unbroken
        // recent context. We never re-summarize a slice we've already
        // covered — the cached summary records exactly which message
        // IDs it abstracts.
        let midpoint = messages.count / 2
        let olderSlice = Array(messages.prefix(midpoint))
        guard !olderSlice.isEmpty else { return }

        let olderIDs = olderSlice.map(\.id)
        if let existing = summaryByConversation[conversationID],
           Set(existing.coversMessageIDs) == Set(olderIDs) {
            // Already up to date — bail before paying for inference.
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.summarizationTasks[conversationID] = nil }

            var summary = await self.summarizer.summarize(messages: olderSlice)
            guard let initial = summary, !initial.isEmpty else {
                HHLog.chat.notice("auto-summary: produced empty output for \(conversationID, privacy: .public) — leaving prior summary intact")
                return
            }

            // Hierarchical pass: if the produced summary itself is too
            // big for the prompt budget (happens on very long
            // conversations where the slice was 30+ turns), recondense
            // it one more time. We synthesise a single Message wrapper
            // so the existing `summarize(messages:)` API can ingest the
            // text without a separate code path.
            let initialTokens = budgeter.tokensAccurate(in: initial)
            if initialTokens > Self.summaryRecondenseTokenThreshold {
                let wrapped = Message(
                    id: UUID(),
                    conversationID: conversationID,
                    role: .assistant,
                    content: initial,
                    createdAt: .now,
                    status: .complete,
                    tokenCount: initialTokens
                )
                if let recondensed = await self.summarizer.summarize(messages: [wrapped]),
                   !recondensed.isEmpty,
                   budgeter.tokensAccurate(in: recondensed) < initialTokens {
                    HHLog.chat.info("auto-summary: hierarchical re-condense \(initialTokens) → \(budgeter.tokensAccurate(in: recondensed)) tokens for \(conversationID, privacy: .public)")
                    summary = recondensed
                } else {
                    // Re-condense degraded or empty — keep the original
                    // and accept the budget cost rather than ship a
                    // worse summary.
                    summary = initial
                }
            }

            guard let finalSummary = summary, !finalSummary.isEmpty else { return }

            // Hard truncation guard. The hierarchical pass should keep
            // most summaries under ~400 tokens, but a misbehaving model
            // (or a custom-loaded community checkpoint with weird
            // outputs) can return a runaway gist of thousands of
            // tokens. Without this guard a single bad summary blows
            // the entire prompt budget for every subsequent turn —
            // silent UX degradation that's hard to diagnose.
            //
            // Clip to byte-length corresponding to `summaryHardClipTokens`
            // via the conservative tokens-per-char proxy. Better to
            // ship a truncated paragraph with "…" than a blown budget.
            let clipped = Self.clipSummaryIfNeeded(finalSummary, budgeter: budgeter)
            self.summaryByConversation[conversationID] = ConversationSummary(
                conversationID: conversationID,
                summary: clipped,
                coversMessageIDs: olderIDs,
                generatedAt: .now
            )
            HHLog.chat.info("auto-summary: condensed \(olderSlice.count) older messages for \(conversationID, privacy: .public) (\(clipped.count) chars)")
        }
        summarizationTasks[conversationID] = task
    }

    /// Hard upper bound on summary size. If the hierarchical pass
    /// failed to bring the gist under the budget — or didn't fire —
    /// this is the last-line clip that protects every downstream turn
    /// from a runaway summary. Calibrated at 2× the recondense
    /// threshold so legitimate "long but useful" summaries survive
    /// and only truly pathological outputs get truncated.
    private static let summaryHardClipTokens = 800

    /// Returns `summary` if it's within `summaryHardClipTokens`,
    /// otherwise a truncated version ending with " […]". Truncation
    /// happens on a word boundary so the clipped output still reads
    /// as natural language. Logs a warning so the developer knows
    /// the hard clip fired — repeated hits in Diagnostics indicate a
    /// model returning bad summaries.
    private static func clipSummaryIfNeeded(_ summary: String, budgeter: PromptTokenBudgeter) -> String {
        let tokens = budgeter.tokensAccurate(in: summary)
        guard tokens > summaryHardClipTokens else { return summary }

        // Convert token target back to an approximate char count via
        // the family's tokens-per-char ratio. We err small (0.8×) so
        // the clipped result is comfortably under the bound rather
        // than right at the edge — leaves room for the " […]" marker
        // and a safety margin against the heuristic's ±15 % error.
        let targetChars = Int(Double(summary.count) * Double(summaryHardClipTokens) / Double(tokens) * 0.8)
        let clipPoint = max(100, min(summary.count, targetChars))
        // Walk back to the nearest whitespace so we don't slice mid-word.
        var idx = summary.index(summary.startIndex, offsetBy: clipPoint)
        while idx > summary.startIndex && !summary[idx].isWhitespace {
            idx = summary.index(before: idx)
        }
        let clipped = String(summary[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + " […]"
        HHLog.chat.warning("auto-summary: hard-clipped from \(tokens) to ≤\(summaryHardClipTokens) tokens (\(summary.count) → \(clipped.count) chars) — runaway model output")
        return clipped
    }

    /// Above this token count, the summarizer re-condenses its own
    /// output once. Calibrated so the summary plus persona + facts +
    /// recall still fits under the typical 4096-token context with
    /// room for history and generation. 400 tokens is roughly a
    /// long paragraph — usable as context, not bloated.
    private static let summaryRecondenseTokenThreshold = 400

    /// Continuous summarisation trigger curve.
    ///
    /// **Inputs:**
    /// - `budget`: `profile.safeHistoryTokenBudget`. Already
    ///   device-scaled by `ModelCapabilityProfile.dynamicHistoryBudget`
    ///   so a tight-tier iPhone sees a smaller value than an M-series
    ///   iPad on the same model.
    /// - `isWeak`: shifts the curve ~10 points earlier for models
    ///   that lose coherence on long raw history.
    ///
    /// **Output:** fraction of the budget at which auto-summarise
    /// fires. Linear from `0.45 @ 400-token budget` to
    /// `0.75 @ 2800-token budget`, clamped at the ends. The slope is
    /// calibrated against empirical chat-quality samples: below 400
    /// tokens any context bleed is fatal so we summarise aggressively;
    /// above 2800 tokens (generous tier) the model has enough working
    /// memory that summarising prematurely wastes the buffer.
    ///
    /// Pure function — exposed `static` for direct unit testing
    /// without spinning up the surrounding actor.
    static func summarizationTriggerFraction(budget: Int, isWeak: Bool) -> Double {
        let lo = 400.0
        let hi = 2800.0
        let loFraction = 0.45
        let hiFraction = 0.75
        let b = max(lo, min(hi, Double(budget)))
        let t = (b - lo) / (hi - lo)        // 0 … 1
        let base = loFraction + (hiFraction - loFraction) * t
        // Weak models shift the curve ~0.10 earlier but never below 0.40
        // (summarising under 40% of budget is wasted work — the
        // summariser itself needs enough raw context to produce a
        // sensible condensed output).
        let adjusted = isWeak ? max(0.40, base - 0.10) : base
        return adjusted
    }

    // MARK: - Episode auto-write-back

    /// Scans conversations that have been idle long enough to count as
    /// "the user has moved on" and writes back a `MemoryEpisode` for
    /// each one that hasn't been episodized yet. Triggered by
    /// `AppContainer.handleScenePhaseChange(.background)` so the user's
    /// long-form conversations leave a searchable trace in long-term
    /// memory without the user having to remember to approve a
    /// memory candidate during the chat itself.
    ///
    /// **Why on background, not on chat-switch.** Chat-switch fires
    /// far more often than the user "closing" the conversation in
    /// their head — they might just be cross-referencing two
    /// conversations. App background is a clean signal: the user is
    /// done for now, episodization can run without competing for
    /// model time with anything else the user is doing.
    ///
    /// **Approval model.** Episodes are written as `approved: false`
    /// to mirror the existing extraction flow — the user reviews them
    /// in the Memory tab. Auto-approval would silently inflate the
    /// retrieval pool with low-quality gists; the manual review is
    /// the quality gate.
    ///
    /// **De-duplication.** We don't episodize a conversation that
    /// already has *any* episode with the same `sourceConversationID`
    /// (approved or pending). Re-episodizing on every background
    /// would clutter the candidates list; the existing episode is
    /// either approved (still relevant) or pending review (user
    /// will revisit).
    func autoEpisodizeIdleConversations(
        idleThreshold: TimeInterval = 10 * 60
    ) async {
        guard settings.current.memoryEnabled,
              settings.current.autoExtractMemory,
              runtime.activeModel != nil else { return }

        let now = Date()
        let candidates = conversations.filter { conv in
            now.timeIntervalSince(conv.updatedAt) >= idleThreshold
        }
        guard !candidates.isEmpty else { return }

        // Snapshot existing episodes once — checking per-conversation
        // inside the loop would re-iterate the list every time.
        let alreadyEpisodized = Set(
            memory.episodes.map(\.sourceConversationID)
        )

        for conv in candidates where !alreadyEpisodized.contains(conv.id) {
            // Skip if the conversation was deleted or hasn't loaded
            // into the cache. The store-backed fetch would work but
            // we'd rather episodize what the user has actually
            // touched recently (i.e. it's in the cache).
            guard let messages = messagesByConversation[conv.id],
                  messages.count >= Self.minMessagesForEpisode else { continue }

            // Source message is the last user turn — that's what the
            // episode is "about" from the user's perspective. The
            // model-summarized gist is `summary`.
            guard let lastUser = messages.last(where: { $0.role == .user }) else { continue }

            let summary = await summarizer.summarize(messages: messages)
            guard let summary, !summary.isEmpty else {
                HHLog.memory.notice("auto-episode: empty summary for \(conv.id, privacy: .public) — skipping")
                continue
            }

            // Route through the candidates flow instead of writing the
            // episode straight to `memory.episodes`. Two reasons:
            //   1. Bulk approve/dismiss in the Memory tab operates on
            //      candidates — putting auto-episodes there means the
            //      user can sweep them in one tap rather than swiping
            //      each row individually.
            //   2. The existing UX already conditions users to "review
            //      candidates" as the approval ceremony; auto-episodes
            //      that bypass it would feel like silent injection.
            let candidate = MemoryCandidate(
                id: UUID(),
                content: summary,
                kind: .episode,
                category: .other,
                sourceConversationID: conv.id,
                sourceMessageID: lastUser.id,
                proposedAt: .now,
                extractionMethod: .structured
            )
            await memory.appendCandidate(candidate)
            HHLog.memory.info("auto-episode: proposed candidate for \(conv.id, privacy: .public) (\(summary.count) chars)")
        }
    }

    /// Below this message count an idle conversation is not worth
    /// episodizing — a 3-turn chat is its own summary. The summarizer
    /// also produces low-quality outputs for very short inputs, so
    /// the floor doubles as a quality guard.
    private static let minMessagesForEpisode = 8

    // MARK: - Speculative retrieval prefetch

    /// Debounced prefetch of fact/episode/recall embeddings for a
    /// draft message. Wired into `MessageComposerView`'s text-change
    /// hook so that by the time the user taps Send the embedding LRU
    /// for the likely retrieval set is already hot, shaving 50-200ms
    /// off perceived send latency on iPhone.
    ///
    /// **Cancellation.** Each call cancels the prior in-flight prefetch
    /// for the same conversation — typing keeps moving the target, no
    /// reason to keep stale prefetches alive. Bursting keystrokes
    /// produce at most one round-trip per `prefetchDebounceMs`.
    ///
    /// **Minimum draft length.** Below `prefetchMinChars` the draft is
    /// too vague (a single word like "ok") to yield useful retrieval —
    /// running the prefetch would just bloat the LRU with low-quality
    /// vectors. The threshold matches the "trivial reply" floor in
    /// `MessageImportance.score`, keeping the two heuristics aligned.
    ///
    /// **No state mutation.** The prefetch does NOT pre-compute the
    /// `PromptContextPackage`; that would race with the real send
    /// (which may pick a different model or settings snapshot). It
    /// only warms the embedding cache as a side effect of running the
    /// same batch-similarity call the send path would issue.
    func prefetchRetrieval(for draft: String, in conversationID: UUID) {
        prefetchTasks[conversationID]?.cancel()

        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.prefetchMinChars,
              settings.current.memoryEnabled else {
            prefetchTasks[conversationID] = nil
            return
        }

        prefetchTasks[conversationID] = Task { [weak self, memory] in
            // Debounce. Sleeping at the start lets a fast burst of
            // keystrokes coalesce into the single most-recent draft;
            // cancellation during the sleep is the common path.
            try? await Task.sleep(nanoseconds: UInt64(Self.prefetchDebounceMs) * 1_000_000)
            guard !Task.isCancelled, let self else { return }

            // Run the same retrieval calls the send path would —
            // their side effect is to populate the embedding LRU.
            // We ignore the returned values; the next send will read
            // from a warm cache and skip the network/compute.
            let (factLimit, episodeLimit) = Self.adaptiveRetrievalLimits(for: trimmed)
            _ = await memory.relevantFacts(for: trimmed, limit: factLimit)
            _ = await memory.relevantEpisodes(for: trimmed, limit: episodeLimit)

            // Warm recall over the live history too — recall uses a
            // different EmbeddingService entry per message, so the
            // facts/episodes warm-up doesn't cover it.
            let history = self.messagesByConversation[conversationID] ?? []
            if !history.isEmpty {
                _ = await self.recall.recall(
                    query: trimmed,
                    from: history,
                    excluding: [],
                    limit: 3
                )
            }
        }
    }

    /// Per-conversation prefetch task handle. Cancelled and replaced
    /// on every text-change so we never have two parallel prefetches
    /// thrashing the embedding cache for the same conversation.
    private var prefetchTasks: [UUID: Task<Void, Never>] = [:]

    /// Debounce window for typing-driven prefetch. 300 ms catches a
    /// natural pause between words without firing on every keystroke.
    private static let prefetchDebounceMs = 300

    /// Drafts shorter than this skip the prefetch — too vague to
    /// produce useful retrieval, and the LRU shouldn't be polluted
    /// with vectors for "ok" / "hm" / "díky".
    private static let prefetchMinChars = 12

    // MARK: - Diagnostics snapshot

    /// Lightweight snapshot of the chat-memory subsystem's current
    /// state. Consumed by `DeveloperDiagnosticsView` so a developer
    /// (or a power user filing a bug) can answer "is the summarizer
    /// keeping up? is recall warm? how many drafts are mid-prefetch?"
    /// at a glance without attaching Xcode.
    ///
    /// All fields are derived from in-memory state — no I/O, safe to
    /// call on the main actor at any UI cadence.
    struct ChatMemorySnapshot: Equatable {
        /// Total conversations persisted (cached + on-disk).
        let totalConversations: Int
        /// Conversations whose messages are loaded in the LRU.
        let cachedConversations: Int
        /// Cached summaries — one per conversation that's been
        /// auto-summarized at least once.
        let summariesCached: Int
        /// Currently-running summarization tasks. A non-zero value
        /// during normal use is fine; chronically non-zero (10+ over
        /// a session) suggests the summarizer is racing with sends
        /// or the model is too slow to keep up.
        let summariesInProgress: Int
        /// Per-conversation prefetch tasks in flight. Should be 0 or 1
        /// at any given moment — a higher number means the debounce
        /// or cancellation invariants are leaking.
        let prefetchesInProgress: Int
        /// Newest summary timestamp across all conversations, or nil
        /// if none cached. Useful for "did anything actually run in
        /// the last hour?" triage.
        let mostRecentSummaryAt: Date?
    }

    /// Read-only snapshot of the chat-memory subsystem. Recomputed on
    /// every call — there's no caching layer because the underlying
    /// state changes rarely enough that observed-recompute is cheaper
    /// than maintaining a derived published property.
    func chatMemorySnapshot() -> ChatMemorySnapshot {
        let mostRecent = summaryByConversation.values
            .map(\.generatedAt)
            .max()
        return ChatMemorySnapshot(
            totalConversations: conversations.count,
            cachedConversations: messagesByConversation.count,
            summariesCached: summaryByConversation.count,
            summariesInProgress: summarizationTasks.count,
            prefetchesInProgress: prefetchTasks.count,
            mostRecentSummaryAt: mostRecent
        )
    }

    /// Per-conversation handle for an in-flight summarization task.
    /// Used as a re-entrancy guard so a fast burst of sends doesn't
    /// queue multiple summarization runs against the same MLX context.
    private var summarizationTasks: [UUID: Task<Void, Never>] = [:]

    /// Below this message count the auto-summarizer never fires —
    /// the budgeter can keep the entire history in-prompt for short
    /// conversations and the summary would just add latency on the
    /// next turn without a recall benefit.
    private static let minMessagesForSummary = 12

    /// Force the summarizer to run for `conversationID` regardless of
    /// the usual budget / message-count gates. Used by the chat menu
    /// "Summarize now" action so a power user can manually compress
    /// older context before sending a complex follow-up — useful when
    /// the auto-trigger hasn't fired yet (history is below 70 % of
    /// budget) but the next turn is known to push it over.
    ///
    /// **Re-entrancy.** Routes through the same `summarizationTasks`
    /// guard as the auto path; a manual tap while a background
    /// summarization is in flight no-ops and returns `false`, with the
    /// caller free to surface a "summarization already running" toast.
    ///
    /// **Why a public bool return.** Lets the UI distinguish "I
    /// didn't run because conditions weren't met" (no model loaded,
    /// not enough messages, already running) from "I ran and
    /// produced a fresh summary" without exposing internal state.
    @discardableResult
    func forceSummarizeNow(in conversationID: UUID) async -> Bool {
        guard runtime.activeModel != nil,
              summarizationTasks[conversationID] == nil else { return false }

        let messages = messagesByConversation[conversationID] ?? []
        // Manual path still respects the "too short to summarize"
        // floor — a 4-message chat has nothing meaningful to condense
        // and the summarizer would produce a low-quality output.
        guard messages.count >= 4 else { return false }

        let profile = ModelCapabilityProfile.resolve(
            family: runtime.activeModel?.family ?? "",
            parameterCount: runtime.activeModel?.parameterCount,
            contextLength: runtime.activeModel?.contextLength
        )
        let budgeter = PromptTokenBudgeter(profile: profile)

        // Use the same "older half" slicing as the auto path so the
        // summary semantically slots in the same place. A user
        // triggering "Summarize now" right after a long brainstorm
        // expects the result to abstract the brainstorm and leave
        // their final question intact.
        let midpoint = messages.count / 2
        let olderSlice = Array(messages.prefix(midpoint))
        guard !olderSlice.isEmpty else { return false }

        let olderIDs = olderSlice.map(\.id)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.summarizationTasks[conversationID] = nil }
            guard let summary = await self.summarizer.summarize(messages: olderSlice),
                  !summary.isEmpty else {
                HHLog.chat.notice("manual-summary: empty output for \(conversationID, privacy: .public)")
                return
            }
            let clipped = Self.clipSummaryIfNeeded(summary, budgeter: budgeter)
            self.summaryByConversation[conversationID] = ConversationSummary(
                conversationID: conversationID,
                summary: clipped,
                coversMessageIDs: olderIDs,
                generatedAt: .now
            )
            HHLog.chat.info("manual-summary: condensed \(olderSlice.count) older messages for \(conversationID, privacy: .public)")
        }
        summarizationTasks[conversationID] = task
        await task.value
        // task.value implicitly waits for the deferred clear, so by
        // the time we return here the call site can read
        // `summaryByConversation[id]` directly if it wants to render
        // a confirmation toast.
        return true
    }

    /// Adaptive (fact_limit, episode_limit) for a user input.
    ///
    /// The numbers are bucketed (not interpolated) so the behaviour is
    /// predictable and easy to debug from a Diagnostics log: "short
    /// input → (3, 1)". The buckets are calibrated so that:
    ///   - Trivial messages ("ok", "thanks", "yes") get the minimum
    ///     viable context — usually pinned + 1-2 keyword hits.
    ///   - Medium messages (a sentence or two) get the established
    ///     defaults (8, 3) — the historic baseline.
    ///   - Long messages (multi-paragraph queries) get a deeper pull
    ///     so the model has the grounding to write a structured
    ///     answer instead of a generic summary.
    ///
    /// Pinned facts bypass these limits (see `MemoryService.relevantFacts`),
    /// so even the "short" bucket can return many facts when the user
    /// has pinned them.
    nonisolated static func adaptiveRetrievalLimits(for input: String) -> (facts: Int, episodes: Int) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.count {
        case 0..<30:     return (3, 1)   // "ok", "díky", "yes please"
        case 30..<200:   return (8, 3)   // baseline — single sentence to short paragraph
        default:         return (12, 5)  // long, deliberate query — deep pull
        }
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
