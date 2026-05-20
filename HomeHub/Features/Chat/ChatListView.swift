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
    /// When true, the list reveals archived conversations in a
    /// dedicated section beneath the active ones. Off by default so
    /// archiving actually clears the chat away from the user's
    /// everyday surface — re-enabling here is the audited way back in.
    @State private var showArchived: Bool = false

    /// Filters conversations by title, last-message preview, and full
    /// message body content (case insensitive). Empty `searchText`
    /// returns the full list so the search field doesn't change
    /// behaviour until the user actually types something.
    ///
    /// Title/preview matches are evaluated synchronously here; body
    /// matches come from `ConversationService.lastDeepSearchMatches`
    /// which the service populates incrementally as it loads cold
    /// conversations from the store. Merging both sources means a chat
    /// matching only on a buried message still appears in the list,
    /// while title-only matches don't have to wait for the async scan.
    private var filteredConversations: [Conversation] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return conversations.conversations }
        let needle = trimmed.lowercased()
        let deepMatches = conversations.lastDeepSearchMatches
        return conversations.conversations.filter { convo in
            convo.title.lowercased().contains(needle)
                || (convo.lastMessagePreview?.lowercased().contains(needle) ?? false)
                || deepMatches.contains(convo.id)
        }
    }

    // MARK: - Section partitioning

    /// True while the user is actively filtering — collapses the
    /// pin/archive sectioning into a single flat list so matches don't
    /// disappear into a hidden "Archived" section just because the
    /// user happens to be searching for an archived chat.
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Conversations to display in the unfiltered case, partitioned
    /// into (pinned, recent, archived). Each bucket is sorted by
    /// `updatedAt` descending so the most recent activity is at the
    /// top of its own section.
    private struct Buckets {
        var pinned: [Conversation]
        var recent: [Conversation]
        var archived: [Conversation]
    }

    private var buckets: Buckets {
        var pinned: [Conversation] = []
        var recent: [Conversation] = []
        var archived: [Conversation] = []
        for c in conversations.conversations {
            if c.archived { archived.append(c) }
            else if c.pinned { pinned.append(c) }
            else { recent.append(c) }
        }
        let byRecent: (Conversation, Conversation) -> Bool = { $0.updatedAt > $1.updatedAt }
        return Buckets(
            pinned:   pinned.sorted(by: byRecent),
            recent:   recent.sorted(by: byRecent),
            archived: archived.sorted(by: byRecent)
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if conversations.conversations.isEmpty {
                    HHEmptyState(
                        icon: "bubble.left.and.bubble.right",
                        title: "Začni první chat",
                        subtitle: "Konverzace se ukládají jen na tomto zařízení. Použijí ten model, který je právě načtený."
                    ) {
                        Button("Nový chat") {
                            Task { await startNewChat() }
                        }
                        .buttonStyle(HHPrimaryButtonStyle())
                    }
                } else if filteredConversations.isEmpty {
                    // While the body-text scan is still streaming
                    // matches in, hint that the result may grow
                    // momentarily — otherwise the empty state reads
                    // as "no matches" even when work is in flight.
                    HHEmptyState(
                        icon: conversations.isDeepSearching ? "ellipsis.circle" : "magnifyingglass",
                        title: conversations.isDeepSearching ? "Hledám ve zprávách…" : "Nic nenalezeno",
                        subtitle: conversations.isDeepSearching
                            ? "Procházím starší chaty pro: \(searchText)"
                            : "Žádné konverzace neodpovídají: \(searchText)"
                    )
                } else {
                    List {
                        if isSearching {
                            // Flat list during search — sectioning into
                            // pinned/recent/archived would only hide
                            // matches that happen to live in another
                            // bucket.
                            Section {
                                ForEach(filteredConversations) { convo in
                                    chatRow(convo)
                                }
                            }
                        } else {
                            let b = buckets
                            if !b.pinned.isEmpty {
                                Section("Připnuté") {
                                    ForEach(b.pinned) { convo in
                                        chatRow(convo)
                                    }
                                }
                            }
                            Section(b.pinned.isEmpty ? "" : "Nedávné") {
                                ForEach(b.recent) { convo in
                                    chatRow(convo)
                                }
                            }
                            if !b.archived.isEmpty {
                                Section {
                                    if showArchived {
                                        ForEach(b.archived) { convo in
                                            chatRow(convo)
                                        }
                                    }
                                } header: {
                                    HStack {
                                        Text("Archivované")
                                        Spacer()
                                        Button(showArchived ? "Skrýt" : "Zobrazit (\(b.archived.count))") {
                                            withAnimation { showArchived.toggle() }
                                        }
                                        .font(HHTheme.caption.weight(.semibold))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(HHTheme.accent)
                                    }
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
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Hledat v chatech")
            // Kick off the async body-text scan whenever the query
            // changes. The service debounces internally by cancelling
            // any in-flight scan before starting the new one, so a
            // burst of keystrokes coalesces to a single sweep.
            .onChange(of: searchText) { _, newValue in
                conversations.searchInMessages(query: newValue)
            }
            .onDisappear {
                // Free the in-flight scan + match cache when the user
                // leaves the chat tab so the next visit starts clean.
                conversations.clearDeepSearch()
            }
            .navigationTitle("Chaty")
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

    /// Single row builder shared by every section (pinned / recent /
    /// archived / search results) so swipe actions and the
    /// NavigationLink wiring stay consistent across them.
    ///
    /// Three swipe affordances:
    ///   - leading: pin / unpin
    ///   - trailing (full-swipe): delete
    ///   - trailing (manual): archive / unarchive
    ///
    /// Archive is intentionally NOT full-swipe — destructive-looking
    /// gestures should require an explicit tap so the user doesn't
    /// nuke a chat away from view while just trying to scroll.
    @ViewBuilder
    private func chatRow(_ convo: Conversation) -> some View {
        NavigationLink(value: convo.id) {
            ChatRowView(conversation: convo)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                HHHaptics.impact(.light, enabled: settings.current.haptics)
                Task { await conversations.setPinned(!convo.pinned, conversationID: convo.id) }
            } label: {
                Label(convo.pinned ? "Odepnout" : "Připnout",
                      systemImage: convo.pinned ? "pin.slash" : "pin.fill")
            }
            .tint(HHTheme.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                HHHaptics.notification(.warning, enabled: settings.current.haptics)
                Task { await conversations.deleteConversation(convo.id) }
            } label: {
                Label("Smazat", systemImage: "trash")
            }
            Button {
                HHHaptics.impact(.light, enabled: settings.current.haptics)
                Task { await conversations.setArchived(!convo.archived, conversationID: convo.id) }
            } label: {
                Label(convo.archived ? "Odarchivovat" : "Archivovat",
                      systemImage: convo.archived ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(.gray)
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
            HStack(spacing: 6) {
                if conversation.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HHTheme.accent)
                        .accessibilityLabel("Pinned")
                }
                Text(conversation.title)
                    .font(HHTheme.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if conversation.archived {
                    Image(systemName: "archivebox")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HHTheme.textSecondary)
                        .accessibilityLabel("Archived")
                }
            }
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
        case .idle:      return .gray
        case .unloading: return HHTheme.warning
        case .loading:   return HHTheme.warning
        case .ready:     return HHTheme.success
        case .failed:    return HHTheme.danger
        }
    }

    private var label: String {
        switch state {
        case .idle:      return "No model"
        case .unloading: return "Unloading"
        case .loading:   return "Loading"
        case .ready:     return "Ready"
        case .failed:    return "Error"
        }
    }
}
