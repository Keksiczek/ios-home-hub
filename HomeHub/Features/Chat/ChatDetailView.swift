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
    @State private var editingMessageID: UUID?
    @State private var editingText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            unloadBanner
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HHTheme.spaceM) {
                        ForEach(messages) { message in
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
                                } : nil
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, HHTheme.spaceL)
                    .padding(.vertical, HHTheme.spaceL)
                }
                .onChange(of: messages.last?.content) { _, _ in
                    guard let last = messages.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    guard let last = messages.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
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
        }
        .background(HHTheme.canvas)
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
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

                        ShareLink(item: exportText) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(messages.isEmpty)

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

    // MARK: - Derived state

    private var messages: [Message] {
        conversations.messages(in: conversationID)
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
