import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var memory: MemoryService
    @EnvironmentObject private var settings: SettingsService
    @EnvironmentObject private var appState: AppState
    @State private var showingAdd = false
    @State private var showingClearConfirm = false
    /// Currently flashing fact (deep-link landing target). Cleared
    /// after ~1.5 s so the row returns to its normal background.
    @State private var highlightedFactID: UUID?

    private var hapticsEnabled: Bool { settings.current.haptics }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Group {
                if memory.facts.isEmpty && memory.episodes.isEmpty && memory.candidates.isEmpty {
                    HHEmptyState(
                        icon: "sparkles",
                        title: "Nothing remembered yet",
                        subtitle: "As you chat, the assistant can propose facts worth remembering. You decide what's saved."
                    ) {
                        Button("Add a fact") { showingAdd = true }
                            .buttonStyle(HHPrimaryButtonStyle())
                    }
                } else {
                    List {
                        if !memory.candidates.isEmpty {
                            Section {
                                ForEach(memory.candidates) { candidate in
                                    CandidateRow(candidate: candidate) {
                                        HHHaptics.notification(.success, enabled: hapticsEnabled)
                                        Task { await memory.accept(candidate) }
                                    } onReject: {
                                        HHHaptics.impact(.light, enabled: hapticsEnabled)
                                        memory.reject(candidateID: candidate.id)
                                    }
                                }
                                // Bulk-action row appears once there
                                // are 2+ candidates — for a single
                                // pending row the per-row Approve/
                                // Reject buttons are already inline.
                                // Two-candidate threshold prevents a
                                // pointless "Approve all (1)" button.
                                if memory.candidates.count >= 2 {
                                    HStack(spacing: HHTheme.spaceM) {
                                        Button {
                                            HHHaptics.notification(.success, enabled: hapticsEnabled)
                                            Task { await memory.acceptAllCandidates() }
                                        } label: {
                                            Label("Approve all (\(memory.candidates.count))",
                                                  systemImage: "checkmark.circle.fill")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(HHTheme.accent)

                                        Button(role: .destructive) {
                                            HHHaptics.impact(.light, enabled: hapticsEnabled)
                                            memory.rejectAllCandidates()
                                        } label: {
                                            Label("Dismiss all", systemImage: "xmark.circle")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    .padding(.top, 4)
                                }
                            } header: {
                                HStack {
                                    Text("Proposed")
                                    Spacer()
                                    // Quick total chip — answers "how
                                    // many things am I being asked to
                                    // review?" without scanning the
                                    // list manually.
                                    if memory.candidates.count >= 2 {
                                        Text("\(memory.candidates.count)")
                                            .font(HHTheme.caption.weight(.semibold))
                                            .foregroundStyle(HHTheme.accent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(HHTheme.accent.opacity(0.15), in: Capsule())
                                    }
                                }
                            }
                        }

                        if !memory.facts.isEmpty {
                            Section("Remembered facts") {
                                ForEach(memory.facts) { fact in
                                    FactRow(fact: fact,
                                            onTogglePin: {
                                                Task { await memory.setPinned(!fact.pinned, for: fact.id) }
                                            },
                                            onToggleDisabled: {
                                                Task { await memory.setDisabled(!fact.disabled, for: fact.id) }
                                            })
                                    // Tag for deep-link scrolling +
                                    // flash background on hit.
                                    .id(fact.id)
                                    .listRowBackground(
                                        highlightedFactID == fact.id
                                            ? Color.yellow.opacity(0.25)
                                            : Color(.secondarySystemGroupedBackground)
                                    )
                                }
                                .onDelete { offsets in
                                    let targets = offsets.map { memory.facts[$0] }
                                    for fact in targets {
                                        Task { await memory.delete(fact.id) }
                                    }
                                }
                            }
                        }

                        if !memory.episodes.isEmpty {
                            Section("Episodes") {
                                ForEach(memory.episodes) { episode in
                                    EpisodeRow(
                                        episode: episode,
                                        onToggleDisabled: {
                                            Task { await memory.setEpisodeDisabled(!episode.disabled, for: episode.id) }
                                        },
                                        onOpenSource: {
                                            // Route through the central
                                            // DeepLink machinery so the
                                            // chat tab uses the same
                                            // open-by-ID path that
                                            // Spotlight + Shortcuts use.
                                            appState.handle(
                                                deepLink: .conversation(episode.sourceConversationID)
                                            )
                                        }
                                    )
                                }
                                .onDelete { offsets in
                                    let targets = offsets.map { memory.episodes[$0] }
                                    for episode in targets {
                                        Task { await memory.deleteEpisode(episode.id) }
                                    }
                                }
                            }
                        }

                        Section {
                            Button(role: .destructive) {
                                HHHaptics.impact(.light, enabled: hapticsEnabled)
                                showingClearConfirm = true
                            } label: {
                                Label("Clear all memory", systemImage: "trash")
                            }
                        } footer: {
                            Text("Memory is stored only on this device. Clearing is immediate and permanent.")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Memory")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarMenuButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddFactSheet { fact in
                    Task { await memory.add(fact) }
                }
            }
            .confirmationDialog(
                "Clear all memory?",
                isPresented: $showingClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear everything", role: .destructive) {
                    HHHaptics.notification(.warning, enabled: hapticsEnabled)
                    Task { await memory.clearAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes all remembered facts and episodes. This can't be undone.")
            }
            .overlay(alignment: .top) {
                if !settings.current.memoryEnabled {
                    MemoryDisabledBanner()
                }
            }
            .onChange(of: appState.pendingDeepLink) { _, _ in
                consumePendingDeepLinkIfMatching(proxy: proxy)
            }
            .task {
                consumePendingDeepLinkIfMatching(proxy: proxy)
            }
            } // ScrollViewReader
        }
    }

    /// Pulls a `.memoryFact(id)` deep link off `AppState`, scrolls
    /// the matching row into view, flashes its background, and
    /// clears the pending link. Falls through silently for any
    /// other deep-link type.
    private func consumePendingDeepLinkIfMatching(proxy: ScrollViewProxy) {
        guard case .memoryFact(let id) = appState.pendingDeepLink else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .top) }
            highlightedFactID = id
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { highlightedFactID = nil }
        }
        appState.clearPendingDeepLink()
    }
}

private struct CandidateRow: View {
    let candidate: MemoryCandidate
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceS) {
            HStack {
                HHTagChip(text: kindLabel,
                          symbol: kindSymbol)
                if candidate.kind == .fact {
                    HHTagChip(text: candidate.category.label,
                              symbol: candidate.category.symbol)
                }
                Spacer()
                Text(candidate.proposedAt.formatted(.relative(presentation: .named)))
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Text(candidate.content)
                .font(HHTheme.body)
            HStack {
                Button("Accept", action: onAccept)
                    .font(HHTheme.subheadline)
                    .tint(HHTheme.accent)
                Spacer()
                Button("Reject", role: .destructive, action: onReject)
                    .font(HHTheme.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    private var kindLabel: String {
        switch candidate.kind {
        case .fact:    return "Fact"
        case .episode: return "Episode"
        }
    }

    private var kindSymbol: String {
        switch candidate.kind {
        case .fact:    return "lightbulb"
        case .episode: return "clock.arrow.circlepath"
        }
    }
}

private struct FactRow: View {
    let fact: MemoryFact
    let onTogglePin: () -> Void
    let onToggleDisabled: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HHTagChip(text: fact.category.label, symbol: fact.category.symbol)
                Spacer()
                if fact.pinned {
                    Image(systemName: "pin.fill")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.accent)
                }
                if fact.disabled {
                    Text("Off")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                }
            }
            Text(fact.content)
                .font(HHTheme.body)
                .foregroundStyle(fact.disabled ? HHTheme.textSecondary : HHTheme.textPrimary)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading) {
            Button(action: onTogglePin) {
                Label(fact.pinned ? "Unpin" : "Pin", systemImage: "pin")
            }
            .tint(HHTheme.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: onToggleDisabled) {
                Label(fact.disabled ? "Enable" : "Disable",
                      systemImage: fact.disabled ? "checkmark" : "xmark")
            }
            .tint(fact.disabled ? .green : .gray)
        }
    }
}

private struct EpisodeRow: View {
    let episode: MemoryEpisode
    let onToggleDisabled: () -> Void
    /// Tap-on-row callback. Routes the user back to the source
    /// conversation via the existing `DeepLink.conversation` path —
    /// answers "where did this episode come from?" without making
    /// the user remember which chat the gist describes.
    var onOpenSource: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HHTagChip(text: "Episode", symbol: "clock.arrow.circlepath")
                Spacer()
                Text(episode.createdAt.formatted(.relative(presentation: .named)))
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
                if episode.disabled {
                    Text("Off")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                }
                if onOpenSource != nil {
                    // Chevron hints "this row is tappable" without
                    // adding a full disclosure indicator (which would
                    // imply a separate detail screen, which we don't
                    // have — the tap is a tab-switch + scroll).
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(HHTheme.textSecondary)
                        .accessibilityLabel("Open source conversation")
                }
            }
            Text(episode.summary)
                .font(HHTheme.body)
                .foregroundStyle(episode.disabled ? HHTheme.textSecondary : HHTheme.textPrimary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())  // make full row tappable, not just the text
        .onTapGesture {
            onOpenSource?()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: onToggleDisabled) {
                Label(episode.disabled ? "Enable" : "Disable",
                      systemImage: episode.disabled ? "checkmark" : "xmark")
            }
            .tint(episode.disabled ? .green : .gray)
        }
    }
}

private struct MemoryDisabledBanner: View {
    var body: some View {
        Text("Memory is off. Turn it back on in Settings to let the assistant use what it knows.")
            .font(HHTheme.footnote)
            .foregroundStyle(HHTheme.textSecondary)
            .padding(HHTheme.spaceM)
            .frame(maxWidth: .infinity)
            .background(HHTheme.surface)
    }
}

private struct AddFactSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var category: MemoryFact.Category = .other
    let onSave: (MemoryFact) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Fact") {
                    TextField("e.g. I prefer short answers in the morning",
                              text: $content, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(MemoryFact.Category.allCases) { cat in
                            Label(cat.label, systemImage: cat.symbol).tag(cat)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("New fact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSave(MemoryFact(
                            id: UUID(),
                            content: trimmed,
                            category: category,
                            source: .userManual,
                            confidence: 1.0,
                            createdAt: .now,
                            lastUsedAt: nil,
                            pinned: false,
                            disabled: false
                        ))
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
