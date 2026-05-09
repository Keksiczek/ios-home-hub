import SwiftUI

struct ChatListView: View {
    @EnvironmentObject private var conversations: ConversationService
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var settings: SettingsService
    @State private var searchText = ""

    /// Filters conversations by title and last-message preview, case
    /// insensitively. Empty `searchText` returns the full list so the
    /// search field doesn't change behaviour until the user actually
    /// types something.
    private var filteredConversations: [Conversation] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return conversations.conversations }
        let needle = trimmed.lowercased()
        return conversations.conversations.filter { convo in
            convo.title.lowercased().contains(needle)
                || (convo.lastMessagePreview?.lowercased().contains(needle) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if conversations.conversations.isEmpty {
                    HHEmptyState(
                        icon: "bubble.left.and.bubble.right",
                        title: "Start your first chat",
                        subtitle: "Conversations are stored on this device only. They'll use whichever model is currently loaded."
                    ) {
                        Button("New chat") {
                            Task { await startNewChat() }
                        }
                        .buttonStyle(HHPrimaryButtonStyle())
                    }
                } else if filteredConversations.isEmpty {
                    HHEmptyState(
                        icon: "magnifyingglass",
                        title: "No matches",
                        subtitle: "No conversations match \"\(searchText)\"."
                    )
                } else {
                    List {
                        ForEach(filteredConversations) { convo in
                            NavigationLink {
                                ChatDetailView(conversationID: convo.id)
                                    .navigationTitle(convo.title)
                                    .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                ChatRowView(conversation: convo)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    HHHaptics.notification(.warning, enabled: settings.current.haptics)
                                    Task { await conversations.deleteConversation(convo.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search chats")
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarMenuButton()
                }
                ToolbarItem(placement: .topBarLeading) {
                    RuntimeBadge(state: runtime.state)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await startNewChat() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
        }
    }

    private func startNewChat() async {
        HHHaptics.impact(.medium, enabled: settings.current.haptics)
        _ = await conversations.createConversation()
    }

    private func delete(at offsets: IndexSet) {
        HHHaptics.notification(.warning, enabled: settings.current.haptics)
        let targets = offsets.map { conversations.conversations[$0] }
        for convo in targets {
            Task { await conversations.deleteConversation(convo.id) }
        }
    }
}

private struct ChatRowView: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(HHTheme.headline)
                .lineLimit(1)
            if let preview = conversation.lastMessagePreview, !preview.isEmpty {
                Text(preview)
                    .font(HHTheme.footnote)
                    .foregroundStyle(HHTheme.textSecondary)
                    .lineLimit(2)
            } else {
                Text("No messages yet")
                    .font(HHTheme.footnote)
                    .foregroundStyle(HHTheme.textSecondary.opacity(0.6))
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RuntimeBadge: View {
    let state: RuntimeManager.State

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        }
    }

    private var color: Color {
        switch state {
        case .idle: return .gray
        case .loading: return HHTheme.warning
        case .ready: return HHTheme.success
        case .failed: return HHTheme.danger
        }
    }

    private var label: String {
        switch state {
        case .idle: return "No model"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .failed: return "Error"
        }
    }
}
