import SwiftUI

struct ChatDetailView: View {
    let conversationID: UUID
    @EnvironmentObject private var conversations: ConversationService
    @EnvironmentObject private var runtime: RuntimeManager
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HHTheme.spaceM) {
                        ForEach(messages) { message in
                            MessageBubbleView(message: message)
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
                onSend: send,
                onCancel: cancel
            )
        }
        .background(HHTheme.canvas)
        .task {
            await conversations.loadMessages(for: conversationID)
        }
    }

    private var messages: [Message] {
        conversations.messages(in: conversationID)
    }

    private var isStreaming: Bool {
        conversations.streamingConversationIDs.contains(conversationID)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isStreaming
            && runtime.activeModel != nil
    }

    private func send() {
        let text = draft
        draft = ""
        conversations.send(userInput: text, in: conversationID)
    }

    private func cancel() {
        conversations.cancelStream(in: conversationID)
    }
}
