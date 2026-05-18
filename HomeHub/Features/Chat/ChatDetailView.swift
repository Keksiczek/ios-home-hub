import SwiftUI

struct ChatDetailView: View {
    let conversationID: UUID
    @EnvironmentObject private var conversations: ConversationService
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var settings: SettingsService
    @EnvironmentObject private var container: AppContainer
    @State private var draft: String = ""
    @State private var showingRename = false
    @State private var showingVoiceCall = false
    @State private var showingClearConfirm = false
    @State private var renameText: String = ""
    /// `true` while a user-initiated `forceSummarizeNow` is in
    /// flight. Drives the menu button's spinner + label and prevents
    /// double-taps from queuing a redundant summarization.
    @State private var isSummarizingManually = false
    @State private var editingMessageID: UUID?
    @State private var editingText: String = ""
    /// User dismissed the context-full banner for the current threshold
    /// crossing. Reset to `false` once `estimatedContextFill` drops back
    /// under 90% so the banner reappears on the next overflow rather
    /// than nagging continuously.
    @State private var contextBannerDismissed: Bool = false

    /// Free-text in-chat finder. Filters the displayed bubbles by
    /// content match while preserving order. Empty string disables
    /// the filter so the chat returns to its normal state.
    @State private var inChatSearch: String = ""

    /// When true, the bubble list is filtered to only bookmarked
    /// messages. Useful for revisiting saved turns without scrolling
    /// the entire thread.
    @State private var showBookmarksOnly: Bool = false

    /// Follow-mode flag for the chat scroll view. While true (default),
    /// new tokens scroll the view to the bottom every yield. The user's
    /// drag gesture flips this to false so they can scroll up to re-read
    /// without the stream fighting them; tapping the "Jump to live" pill
    /// (or sending a new message, or generation finishing) re-enables it.
    @State private var isAutoScrollEnabled: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            unloadBanner
            contextFullBanner
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: HHTheme.spaceM) {
                            if isFilteringChat {
                                filterStatusBar
                            }
                            ForEach(displayedMessages) { message in
                                MessageBubbleView(
                                    message: message,
                                    onRegenerate: canRegenerate(message)
                                        ? { conversations.regenerate(in: conversationID) }
                                        : nil,
                                    onDelete: isStreaming ? nil : {
                                        Task {
                                            await conversations.deleteMessage(
                                                messageID: message.id,
                                                in: conversationID
                                            )
                                        }
                                    },
                                    onEdit: canEdit(message) ? {
                                        editingMessageID = message.id
                                        editingText = message.content
                                    } : nil,
                                    onToggleBookmark: canBookmark(message) ? {
                                        Task {
                                            await conversations.toggleBookmark(
                                                messageID: message.id,
                                                in: conversationID
                                            )
                                        }
                                    } : nil,
                                    isPrefill: isPrefillBubble(message)
                                )
                                .id(message.id)
                            }
                            if isFilteringChat && displayedMessages.isEmpty {
                                emptyFilterPlaceholder
                            }
                        }
                        .padding(.horizontal, HHTheme.spaceL)
                        .padding(.vertical, HHTheme.spaceL)
                    }
                    // Detect user drag during a stream and pause auto-scroll.
                    // Without this guard, every token re-snaps the view back
                    // to the bottom, so users who try to scroll up to re-read
                    // an earlier paragraph end up fighting the stream. Drag
                    // resets autoscroll only after the user has lifted their
                    // finger — the .onEnded re-evaluation runs once the
                    // stream completes via the `.onChange(of: isStreaming)`
                    // hook below. Tapping the floating Jump button (added
                    // beside this stack) explicitly re-enables follow-mode.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8).onChanged { _ in
                            if isAutoScrollEnabled {
                                isAutoScrollEnabled = false
                            }
                        }
                    )
                    .onChange(of: messages.last?.content) { _, _ in
                        guard isAutoScrollEnabled, let last = messages.last else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: messages.count) { _, _ in
                        // A new message ALWAYS wins follow-mode back: the
                        // common case is the user tapped Send, which means
                        // they want to watch the new reply land. If they
                        // scrolled up while typing the next prompt, that
                        // intent is satisfied by sending — re-enable.
                        isAutoScrollEnabled = true
                        guard let last = messages.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: isStreaming) { _, newValue in
                        // Stream finished — release the user from manual
                        // mode so the next turn doesn't appear silently
                        // off-screen.
                        if newValue == false {
                            isAutoScrollEnabled = true
                        }
                    }

                    // Floating "jump to bottom" pill — only visible when
                    // the user has actively scrolled away during a live
                    // stream. Tapping it pins follow-mode and animates
                    // back to the tail.
                    if !isAutoScrollEnabled && isStreaming {
                        Button {
                            isAutoScrollEnabled = true
                            if let last = messages.last {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        } label: {
                            Label("Jump to live", systemImage: "arrow.down.circle.fill")
                                .font(HHTheme.caption.weight(.semibold))
                                .padding(.horizontal, HHTheme.spaceM)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(HHTheme.stroke, lineWidth: 0.5))
                        }
                        .padding(.trailing, HHTheme.spaceL)
                        .padding(.bottom, HHTheme.spaceM)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: isAutoScrollEnabled)
            }

            // Inline busy-model feedback — shown when the user taps Send while
            // a generation is active (same or another conversation).
            // Wrapped in a Group so the .animation drives the transition on
            // the whole block rather than only animating property changes
            // within an already-visible view.
            Group {
                if let feedback = conversations.sendFeedback[conversationID] {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                        Text(feedback)
                            .font(HHTheme.caption)
                    }
                    .foregroundStyle(HHTheme.warning)
                    .padding(.horizontal, HHTheme.spaceL)
                    .padding(.vertical, HHTheme.spaceS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: conversations.sendFeedback[conversationID] != nil)

            // Developer-mode status strip — same toggle that gates the
            // navigation-bar token-usage badge. Surfaces the data we
            // already publish (active model, generation phase, KV
            // cache reuse) so field-debug sessions don't need Xcode.
            if settings.current.showTokenUsage {
                developerStatusStrip
            }

            MessageComposerView(
                draft: $draft,
                isStreaming: isStreaming,
                canSend: canSend,
                tokenFill: estimatedContextFill,
                onSend: { attachments, isWebSearchEnabled in
                    send(attachments: attachments, isWebSearchEnabled: isWebSearchEnabled)
                },
                onCancel: cancel
            )
            // Speculative retrieval prefetch — debounced inside the
            // service so a fast burst of keystrokes coalesces. The
            // service handles cancel-on-resubmit and the minimum
            // draft-length floor; the view just keeps it informed of
            // what the user is currently typing.
            .onChange(of: draft) { _, newDraft in
                conversations.prefetchRetrieval(for: newDraft, in: conversationID)
            }
        }
        .background(HHTheme.canvas)
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        // In-chat finder. Filters the bubble list to matching content
        // while still rendering each match inline (preserving the
        // conversational flow that a separate "results screen" would
        // break). Placement is the navigation bar drawer so it pops
        // out of the way when not in use.
        .searchable(
            text: $inChatSearch,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Find in chat"
        )
        .toolbar {
            if settings.current.showTokenUsage {
                ToolbarItem(placement: .principal) {
                    TokenUsageBadge(
                        title: conversationTitle,
                        fill: estimatedContextFill,
                        contextLength: runtime.activeModel?.contextLength ?? 4096,
                        messages: messages
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    Button {
                        showingVoiceCall = true
                    } label: {
                        Image(systemName: "headphones")
                    }
                    .disabled(isStreaming)

                    Menu {
                        Button {
                            renameText = conversationTitle
                            showingRename = true
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }

                        // Toggle the bookmark filter from the same
                        // menu that hosts Rename / Export — discoverable
                        // alongside the other per-chat actions without
                        // adding a top-level toolbar button.
                        Button {
                            showBookmarksOnly.toggle()
                        } label: {
                            Label(
                                showBookmarksOnly ? "Show all messages" : "Show bookmarks only",
                                systemImage: showBookmarksOnly ? "bookmark.slash" : "bookmark.fill"
                            )
                        }
                        .disabled(!hasAnyBookmark && !showBookmarksOnly)

                        ShareLink(item: exportText) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(messages.isEmpty)

                        // Manual summarize trigger. Surfaces the
                        // background auto-summarizer as a power-user
                        // control. Disabled until the chat has enough
                        // content to summarize meaningfully (matches
                        // `forceSummarizeNow`'s own floor) and during
                        // streaming so we don't race with the live
                        // turn for the runtime.
                        Button {
                            isSummarizingManually = true
                            Task {
                                _ = await conversations.forceSummarizeNow(in: conversationID)
                                isSummarizingManually = false
                            }
                        } label: {
                            if isSummarizingManually {
                                Label("Summarizing…", systemImage: "hourglass")
                            } else {
                                Label("Summarize now", systemImage: "text.append")
                            }
                        }
                        .disabled(messages.count < 4 || isStreaming || isSummarizingManually || runtime.activeModel == nil)

                        Divider()

                        Button(role: .destructive) {
                            showingClearConfirm = true
                        } label: {
                            Label("Clear conversation", systemImage: "trash")
                        }
                        .disabled(messages.isEmpty || isStreaming)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Rename conversation", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                Task { await conversations.rename(conversationID: conversationID, to: t) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingVoiceCall) {
            VoiceCallView(conversationID: conversationID)
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear messages", role: .destructive) {
                Task { await conversations.clearMessages(in: conversationID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every message in this chat. The conversation itself stays in the list.")
        }
        .sheet(item: Binding(
            get: { editingMessageID.map(EditingMessage.init(id:)) },
            set: { editingMessageID = $0?.id }
        )) { editing in
            EditMessageSheet(
                text: $editingText,
                onSave: {
                    conversations.editAndResend(
                        messageID: editing.id,
                        newText: editingText,
                        in: conversationID
                    )
                    editingMessageID = nil
                },
                onCancel: { editingMessageID = nil }
            )
        }
        .task {
            await conversations.loadMessages(for: conversationID)
        }
        .onAppear {
            // Bookkeeping for the LRU cache so the message store doesn't
            // evict the chat the user is actively viewing. `loadMessages`
            // also touches the LRU, but `.onAppear` covers the warm-cache
            // case where the messages are already in memory (typical when
            // switching between recent chats via the sidebar).
            conversations.noteConversationAccess(conversationID)
        }
    }

    // MARK: - Unload banner

    /// Non-blocking banner shown above the chat scroll view when the OS
    /// (memory pressure / thermal critical) forced the model out of
    /// memory. Lets the user one-tap reload back into the chat instead
    /// of hunting for the Models tab and figuring out what happened.
    ///
    /// Hidden when:
    /// - There's no pending notice (`pendingUnloadNotice == nil`).
    /// - The runtime has a model loaded again — in that case the
    ///   problem already resolved itself, so the banner would only
    ///   confuse the user.
    @ViewBuilder
    private var unloadBanner: some View {
        if let notice = container.pendingUnloadNotice,
           runtime.activeModel == nil {
            HStack(spacing: HHTheme.spaceM) {
                Image(systemName: "memorychip")
                    .font(.system(size: 18))
                    .foregroundStyle(HHTheme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.reason.label)
                        .font(HHTheme.subheadline.weight(.semibold))
                    Text("'\(notice.displayName)' will need to reload before chatting.")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Reload") {
                    Task { await container.reloadFromUnloadNotice() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(HHTheme.accent)

                Button {
                    container.acknowledgeUnloadNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HHTheme.textSecondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, HHTheme.spaceL)
            .padding(.vertical, HHTheme.spaceM)
            .background(HHTheme.warning.opacity(0.12))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(HHTheme.warning.opacity(0.35))
                    .frame(height: 1)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Developer status strip

    /// Compact 1-line status strip rendered above the composer when
    /// the developer-mode token-usage toggle is on. Three signals,
    /// all read from data we already publish elsewhere:
    ///   - active model (name + size + backend)
    ///   - generation phase for this conversation (idle/prefill/decoding)
    ///   - KV-cache reuse status for this conversation
    ///
    /// Stays compact (10 pt font, single line where possible) so it
    /// doesn't compete with the chat content for attention.
    @ViewBuilder
    private var developerStatusStrip: some View {
        let model = runtime.activeModel
        let phase = conversations.generationPhase[conversationID]
        let cacheConvID = runtime.runtime.activeSessionConversationID
        let cachePrimed = cacheConvID == conversationID

        HStack(spacing: HHTheme.spaceM) {
            // Model chip — name + backend + size. "—" when no model
            // is loaded so the strip layout doesn't jump.
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .imageScale(.small)
                Text(model?.displayName ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let m = model {
                    Text("\(m.backend.displayName) · \(m.sizeFormatted)")
                        .foregroundStyle(HHTheme.textSecondary)
                }
            }

            Divider().frame(height: 10)

            // Phase chip — colour-coded so prefill (orange) reads
            // distinctly from decoding (green) at a glance.
            HStack(spacing: 4) {
                Image(systemName: phaseIcon(phase))
                    .imageScale(.small)
                    .foregroundStyle(phaseColor(phase))
                Text(phaseLabel(phase))
                    .foregroundStyle(phaseColor(phase))
            }

            Divider().frame(height: 10)

            // KV-cache chip — "Reuse" when this conversation's prefix
            // is warm inside the runtime, "Cold" otherwise.
            HStack(spacing: 4) {
                Image(systemName: cachePrimed ? "memorychip" : "snowflake")
                    .imageScale(.small)
                Text(cachePrimed ? "Reuse cache: ANO" : "Cold start")
                    .foregroundStyle(cachePrimed ? HHTheme.success : HHTheme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(HHTheme.textPrimary)
        .padding(.horizontal, HHTheme.spaceL)
        .padding(.vertical, 4)
        .background(HHTheme.surface.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(HHTheme.stroke)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func phaseLabel(_ phase: ConversationService.GenerationPhase?) -> String {
        switch phase {
        case .prefill?:  return "prefill"
        case .decoding?: return "decoding"
        case nil:        return "idle"
        }
    }

    private func phaseIcon(_ phase: ConversationService.GenerationPhase?) -> String {
        switch phase {
        case .prefill?:  return "brain.head.profile"
        case .decoding?: return "waveform"
        case nil:        return "pause.circle"
        }
    }

    private func phaseColor(_ phase: ConversationService.GenerationPhase?) -> Color {
        switch phase {
        case .prefill?:  return HHTheme.warning
        case .decoding?: return HHTheme.success
        case nil:        return HHTheme.textSecondary
        }
    }

    // MARK: - Context-full banner

    /// Threshold at which the chat starts visibly warning that older
    /// messages may be dropped to fit the context window. Single source
    /// of truth so the dismiss-reset logic can compare against the same
    /// number that drives visibility.
    private static let contextFullThreshold: Double = 0.9

    /// Conservative number of recent messages to keep when the user
    /// taps "Vymazat staré zprávy". Ten turns is enough to preserve
    /// the immediate conversation flow while reclaiming most of the
    /// context budget on a typical chat.
    private static let trimKeepLast: Int = 10

    /// Banner shown when the running context-fill estimate crosses
    /// `contextFullThreshold`. Lets the user explicitly trim the
    /// history (visible action) rather than relying on silent
    /// auto-trim by `PromptTokenBudgeter`. Dismissable per-threshold
    /// so it doesn't reappear after the user has acknowledged it.
    @ViewBuilder
    private var contextFullBanner: some View {
        if estimatedContextFill >= Self.contextFullThreshold,
           !contextBannerDismissed,
           !isStreaming {
            let percent = Int((estimatedContextFill * 100).rounded())
            HStack(spacing: HHTheme.spaceM) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 18))
                    .foregroundStyle(HHTheme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kontext je téměř plný (\(percent) %)")
                        .font(HHTheme.subheadline.weight(.semibold))
                    Text("Starší zprávy se mohou automaticky vynechat.")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Vymazat staré") {
                    Task {
                        await conversations.trimMessages(
                            in: conversationID,
                            keepLast: Self.trimKeepLast
                        )
                        contextBannerDismissed = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(HHTheme.warning)

                Button {
                    contextBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HHTheme.textSecondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ignorovat")
            }
            .padding(.horizontal, HHTheme.spaceL)
            .padding(.vertical, HHTheme.spaceM)
            .background(HHTheme.warning.opacity(0.12))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(HHTheme.warning.opacity(0.35))
                    .frame(height: 1)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            // Reset the dismiss flag once the user drops back below the
            // threshold (e.g. after a trim) so the banner is ready to
            // reappear on the next overflow without an app restart.
            .onChange(of: estimatedContextFill) { _, newValue in
                if newValue < Self.contextFullThreshold - 0.05 {
                    contextBannerDismissed = false
                }
            }
        }
    }

    // MARK: - Derived state

    private var messages: [Message] {
        conversations.messages(in: conversationID)
    }

    /// Messages after the per-chat finder + bookmark-only filter have
    /// been applied. Both filters compose: searching for "auth" while
    /// in bookmark-only mode shows just the bookmarked messages that
    /// also contain "auth". Streaming bubbles are kept visible during
    /// in-chat search so the user can watch a new reply land even
    /// while a filter is active — otherwise the just-arriving answer
    /// would silently miss the filter window.
    private var displayedMessages: [Message] {
        let trimmed = inChatSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isFilteringChat else { return messages }
        return messages.filter { msg in
            if msg.status == .streaming { return true }
            if showBookmarksOnly && !msg.isBookmarked { return false }
            if !trimmed.isEmpty, !msg.content.lowercased().contains(trimmed) {
                return false
            }
            return true
        }
    }

    private var isFilteringChat: Bool {
        showBookmarksOnly
            || !inChatSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasAnyBookmark: Bool {
        messages.contains(where: { $0.isBookmarked })
    }

    /// Small banner shown above the bubble list while either chat
    /// filter is active. Surfaces the active filter state + a
    /// single-tap clear so the user is never stranded inside a
    /// silent filter they forgot about.
    @ViewBuilder
    private var filterStatusBar: some View {
        HStack(spacing: HHTheme.spaceS) {
            Image(systemName: showBookmarksOnly ? "bookmark.fill" : "magnifyingglass")
                .foregroundStyle(showBookmarksOnly ? HHTheme.warning : HHTheme.accent)
            Text(filterStatusText)
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
            Spacer(minLength: 0)
            Button("Clear") {
                inChatSearch = ""
                showBookmarksOnly = false
            }
            .font(HHTheme.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(HHTheme.accent)
        }
        .padding(.horizontal, HHTheme.spaceM)
        .padding(.vertical, HHTheme.spaceS)
        .background(HHTheme.surface, in: Capsule())
        .overlay(Capsule().stroke(HHTheme.stroke, lineWidth: 0.5))
    }

    private var filterStatusText: String {
        let matchCount = displayedMessages.filter { $0.status != .streaming }.count
        let total = messages.count
        switch (showBookmarksOnly, !inChatSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
        case (true, true):
            return "\(matchCount) bookmarked match \"\(inChatSearch)\""
        case (true, false):
            return "\(matchCount) bookmarked of \(total)"
        case (false, true):
            return "\(matchCount) of \(total) match \"\(inChatSearch)\""
        case (false, false):
            return ""
        }
    }

    @ViewBuilder
    private var emptyFilterPlaceholder: some View {
        VStack(spacing: HHTheme.spaceS) {
            Image(systemName: showBookmarksOnly ? "bookmark" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(HHTheme.textSecondary)
            Text(showBookmarksOnly && inChatSearch.isEmpty
                 ? "No bookmarked messages."
                 : "No messages match.")
                .font(HHTheme.footnote)
                .foregroundStyle(HHTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HHTheme.spaceXL)
    }

    private var conversationTitle: String {
        conversations.conversations.first { $0.id == conversationID }?.title ?? "Chat"
    }

    private var isStreaming: Bool {
        conversations.streamingConversationIDs.contains(conversationID)
    }

    private var canSend: Bool {
        // Intentionally does NOT check `conversations.isAnyStreaming`: when
        // another conversation is streaming, the Send button stays tappable
        // so that ConversationService.send() can surface the cross-conversation
        // "Model je zaneprázdněn…" inline feedback. Disabling the button
        // would silently swallow the user's intent.
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isStreaming
            && runtime.activeModel != nil
    }

    /// True for the most recent assistant message regardless of status —
    /// completed replies show "Regenerate", failed/cancelled ones show
    /// "Try again". Either way the underlying `ConversationService.regenerate`
    /// drops the bubble and re-runs from the preceding user message.
    private func canRegenerate(_ message: Message) -> Bool {
        guard message.role == .assistant, !isStreaming else { return false }
        return messages.last(where: { $0.role == .assistant })?.id == message.id
    }

    /// "Edit & resend" only makes sense on the most recent user message —
    /// editing earlier ones in the middle of a chat would orphan
    /// downstream replies in confusing ways. Hide while streaming.
    private func canEdit(_ message: Message) -> Bool {
        guard message.role == .user, !isStreaming else { return false }
        return messages.last(where: { $0.role == .user })?.id == message.id
    }

    /// Bookmarking is allowed on any completed user or assistant
    /// message. System bubbles and in-flight streaming placeholders
    /// are excluded — bookmarking partial content would surface a
    /// half-finished thought when the filter is reopened.
    private func canBookmark(_ message: Message) -> Bool {
        guard message.role != .system else { return false }
        guard message.status == .complete else { return false }
        return true
    }

    /// `true` for the placeholder assistant bubble that is currently in
    /// the prefill phase (runtime is processing the prompt, no tokens
    /// yet). Matches by status + content emptiness so we only swap the
    /// indicator on the bubble that's actually waiting on a first token.
    private func isPrefillBubble(_ message: Message) -> Bool {
        guard conversations.generationPhase[conversationID] == .prefill else { return false }
        guard message.role == .assistant, message.status == .streaming else { return false }
        return message.content.isEmpty
    }

    /// Estimated fraction of the context window used (0.0–1.0).
    /// Delegates to the shared `TokenEstimator` so the badge, the
    /// composer's context-fill bar, and `ConversationService`'s
    /// summarisation trigger all agree on the number.
    private var estimatedContextFill: Double {
        TokenEstimator.contextFill(
            messages: messages,
            contextLength: runtime.activeModel?.contextLength ?? 4096
        )
    }

    /// Formatted conversation text for the share sheet. Applies the
    /// chat-template sanitizer and renders each turn with role label +
    /// timestamp so the exported markdown reads as a proper transcript.
    private var exportText: String {
        let header = "# \(conversationTitle)\n\n"
        let body = messages
            .filter { $0.role != .system }
            .map { msg -> String in
                let label = msg.role == .user ? "You" : "Assistant"
                let stamp = Self.exportTimestampFormatter.string(from: msg.createdAt)
                let clean = ChatTextSanitizer.strip(msg.content)
                return "**\(label) · \(stamp)**\n\n\(clean)"
            }
            .joined(separator: "\n\n---\n\n")
        return header + body
    }

    private static let exportTimestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()

    // MARK: - Actions

    private func send(attachments: [Message.Attachment], isWebSearchEnabled: Bool = false) {
        let text = draft
        draft = ""
        conversations.send(userInput: text, in: conversationID, attachments: attachments, isWebSearchEnabled: isWebSearchEnabled)
    }

    private func cancel() {
        conversations.cancelStream(in: conversationID)
    }
}

/// Wraps a message ID into an `Identifiable` so SwiftUI's `.sheet(item:)`
/// can drive the edit-and-resend modal. SwiftUI binds presence/absence
/// of the sheet to the optionality of this value, which is much cleaner
/// than juggling a separate `isPresented` Bool.
private struct EditingMessage: Identifiable {
    let id: UUID
}

/// Modal text editor used to amend the most recent user message before
/// re-running the assistant turn.
private struct EditMessageSheet: View {
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $text)
                    .padding(HHTheme.spaceM)
                    .background(HHTheme.surface)
                    .cornerRadius(HHTheme.cornerLarge)
                    .padding()
            }
            .background(HHTheme.canvas.ignoresSafeArea())
            .navigationTitle("Edit message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Resend", action: onSave)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Compact token-usage indicator shown in place of the navigation title
/// when `settings.showTokenUsage` is enabled. Uses the shared
/// `TokenEstimator` so the count matches `estimatedContextFill`.
private struct TokenUsageBadge: View {
    let title: String
    let fill: Double
    let contextLength: Int
    let messages: [Message]

    private var usedTokens: Int {
        TokenEstimator.tokens(in: messages)
    }

    private var color: Color {
        if fill > 0.9 { return HHTheme.danger }
        if fill > 0.75 { return HHTheme.warning }
        return HHTheme.textSecondary
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(HHTheme.headline)
                .lineLimit(1)
            Text("\(usedTokens) / \(contextLength) tok")
                .font(HHTheme.caption.monospacedDigit())
                .foregroundStyle(color)
        }
    }
}
