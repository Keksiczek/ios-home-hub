import SwiftUI

struct ChatListView: View {
    @EnvironmentObject private var conversations: ConversationService
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var settings: SettingsService
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    /// Path-based navigation. Storing conversation IDs (rather than
    /// the whole `Conversation`) means a deep link from Spotlight
    /// can push a chat by ID even before the conversations array
    /// has finished loading — ChatDetailView already takes the ID,
    /// so the destination resolves itself.
    @State private var path: [UUID] = []

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
        NavigationStack(path: $path) {
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
                            // Value-based NavigationLink so the
                            // destination is keyed by `UUID` and
                            // can be pushed from outside the view
                            // (Spotlight deep link → `path` mutation).
                            NavigationLink(value: convo.id) {
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
                    .navigationDestination(for: UUID.self) { conversationID in
                        ChatDetailView(conversationID: conversationID)
                            .navigationTitle(
                                conversations.conversations
                                    .first(where: { $0.id == conversationID })?
                                    .title ?? "Chat"
                            )
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search chats")
            .navigationTitle("Chats")
            // Deep-link consumer: Spotlight tap or
            // `homehub://conversation/<UUID>` URL pushes the matching
            // detail view onto the stack. Clearing the pending link
            // afterwards prevents a re-fire on the next state change.
            .onChange(of: appState.pendingDeepLink) { _, newValue in
                consumeDeepLinkIfMatching(newValue)
            }
            .task {
                // Same handler for the case where the deep link was
                // already set when the view first appears (cold-launch
                // path: HomeHubApp processes the activity before the
                // chat tab is even on screen).
                if appState.selectedTab == .chat {
                    consumeDeepLinkIfMatching(appState.pendingDeepLink)
                }
            }
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

    /// Single chokepoint for `pendingDeepLink` consumption inside
    /// the chat tab.
    /// - `.conversation(id)` → push that conversation onto the path.
    /// - `.query(text)` → spawn a fresh conversation, send the
    ///   query as the first user message, and push the new chat
    ///   onto the path. Used by the "Ask Home Hub" App Intent
    ///   when `openAppWhenRun` brings the user back to the app.
    /// Other cases pass through (handled by other tabs).
    private func consumeDeepLinkIfMatching(_ link: DeepLink?) {
        switch link {
        case .conversation(let id):
            if path.last != id { path.append(id) }
            appState.clearPendingDeepLink()
        case .query(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                appState.clearPendingDeepLink()
                return
            }
            // Spawn → send → push. Done in a `Task` so the
            // sync deep-link path doesn't await on conversation
            // creation while the view body is rendering.
            Task {
                let convo = await conversations.createConversation(title: "Ask")
                _ = await conversations.sendAndWait(userInput: trimmed, in: convo.id)
                await MainActor.run {
                    if path.last != convo.id { path.append(convo.id) }
                    appState.clearPendingDeepLink()
                }
            }
        case .document, .memoryFact, .none:
            // Handled by the other tabs' consumers (or no link at all).
            break
        }
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
