import SwiftUI

struct ChatDetailView: View {
    let conversationID: UUID
    @EnvironmentObject private var conversations: ConversationService
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var settings: SettingsService
    @State private var draft: String = ""
    @State private var showingRename = false
    @State private var showingVoiceCall = false
    @State private var renameText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HHTheme.spaceM) {
                        ForEach(messages) { message in
                            MessageBubbleView(
                                message: message,
                                onRegenerate: canRegenerate(message)
                                    ? { conversations.regenerate(in: conversationID) }
                                    : nil
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
        .task {
            await conversations.loadMessages(for: conversationID)
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
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isStreaming
            && runtime.activeModel != nil
    }

    /// Returns true only for the last completed assistant message (shows "Regenerate").
    private func canRegenerate(_ message: Message) -> Bool {
        guard message.role == .assistant,
              message.status == .complete,
              !isStreaming else { return false }
        return messages.last(where: { $0.role == .assistant })?.id == message.id
    }

    /// Estimated fraction of the context window used (0.0–1.0).
    /// Uses the 4-chars-per-token approximation standard in LLM tooling.
    private var estimatedContextFill: Double {
        let contextLength = runtime.activeModel?.contextLength ?? 4096
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        let estimatedTokens = totalChars / 4
        return min(Double(estimatedTokens) / Double(contextLength), 1.0)
    }

    /// Formatted conversation text for the share sheet.
    private var exportText: String {
        let header = "# \(conversationTitle)\n\n"
        let body = messages
            .filter { $0.role != .system }
            .map { msg -> String in
                let label = msg.role == .user ? "You" : "Assistant"
                return "[\(label)]\n\(msg.content)"
            }
            .joined(separator: "\n\n---\n\n")
        return header + body
    }

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

/// Compact token-usage indicator shown in place of the navigation title
/// when `settings.showTokenUsage` is enabled. Uses the same 4-chars-per-
/// token approximation as `ChatDetailView.estimatedContextFill`.
private struct TokenUsageBadge: View {
    let title: String
    let fill: Double
    let contextLength: Int
    let messages: [Message]

    private var usedTokens: Int {
        let chars = messages.reduce(0) { $0 + $1.content.count }
        return chars / 4
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
