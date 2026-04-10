import SwiftUI

struct ChatDetailView: View {
    let conversationID: UUID
    @EnvironmentObject private var conversations: ConversationService
    @EnvironmentObject private var runtime: RuntimeManager
    @State private var draft: String = ""
    @State private var showingRename = false
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
                onSend: send,
                onCancel: cancel
            )
        }
        .background(HHTheme.canvas)
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
        .alert("Rename conversation", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                Task { await conversations.rename(conversationID: conversationID, to: t) }
            }
            Button("Cancel", role: .cancel) {}
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

    private func send() {
        let text = draft
        draft = ""
        conversations.send(userInput: text, in: conversationID)
    }

    private func cancel() {
        conversations.cancelStream(in: conversationID)
    }
}
