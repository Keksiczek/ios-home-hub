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

    /// Fact currently open in the edit sheet. `nil` when no sheet is
    /// presented. Driving the sheet off an optional `MemoryFact?` (rather
    /// than a separate bool + state pair) keeps the sheet's initial
    /// content in sync with whichever row the user tapped.
    @State private var editingFact: MemoryFact?

    /// Free-text filter for the facts/episodes lists. Applied
    /// case-insensitively against fact content and episode summaries.
    @State private var searchText: String = ""

    /// Category chip filter for the facts list. `nil` means "all
    /// categories". Episodes are not categorised so the filter only
    /// affects the facts section.
    @State private var categoryFilter: MemoryFact.Category?

    /// Drives the duplicate-review sheet. Computed lazily from
    /// `memory.facts` on demand (the heuristic is cheap enough that
    /// caching it across @Published updates is more bookkeeping than
    /// it's worth) and re-queried whenever the sheet is reopened.
    @State private var showingDuplicates: Bool = false

    private var hapticsEnabled: Bool { settings.current.haptics }

    /// Facts filtered by the search text and category chip. Returns the
    /// full list when neither filter is active.
    private var filteredFacts: [MemoryFact] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return memory.facts.filter { fact in
            if let cat = categoryFilter, fact.category != cat { return false }
            if !trimmed.isEmpty, !fact.content.lowercased().contains(trimmed) { return false }
            return true
        }
    }

    /// Episodes filtered by search text. Category filter does not apply.
    private var filteredEpisodes: [MemoryEpisode] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            // When the user has picked a category, hide episodes — they
            // don't belong to a category and showing them would look
            // like a filter bug.
            return categoryFilter == nil ? memory.episodes : []
        }
        return memory.episodes.filter { $0.summary.lowercased().contains(trimmed) }
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || categoryFilter != nil
    }

    /// Cheap, deterministic duplicate scan. Recomputed every body
    /// pass — the heuristic is O(n) per category in practice, which
    /// stays under a millisecond for realistic libraries. Avoids
    /// stale state by re-running rather than caching.
    private var duplicatePairs: [MemoryService.DuplicatePair] {
        memory.findDuplicateFacts()
    }

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

                        // Category chip row — only shown when there are
                        // facts AND we're not in the "nothing-yet" empty
                        // state. Hidden during the candidate-only
                        // pre-acceptance period since there's nothing to
                        // filter yet.
                        if !memory.facts.isEmpty {
                            Section {
                                CategoryFilterChips(selection: $categoryFilter)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16,
                                                              bottom: 4, trailing: 16))
                                    .listRowBackground(Color.clear)
                            }
                        }

                        if !filteredFacts.isEmpty {
                            Section("Remembered facts") {
                                ForEach(filteredFacts) { fact in
                                    FactRow(fact: fact,
                                            onTogglePin: {
                                                Task { await memory.setPinned(!fact.pinned, for: fact.id) }
                                            },
                                            onToggleDisabled: {
                                                Task { await memory.setDisabled(!fact.disabled, for: fact.id) }
                                            },
                                            onEdit: {
                                                editingFact = fact
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
                                    // Map offsets through `filteredFacts`
                                    // — without this, a delete during an
                                    // active filter would index into the
                                    // unfiltered list and remove the
                                    // wrong fact.
                                    let targets = offsets.map { filteredFacts[$0] }
                                    for fact in targets {
                                        Task { await memory.delete(fact.id) }
                                    }
                                }
                            }
                        } else if !memory.facts.isEmpty && isFiltering {
                            // Filter active but nothing matched — show a
                            // small inline note instead of a silent gap
                            // between the chip row and the episodes
                            // section.
                            Section {
                                Text("No facts match your filter.")
                                    .font(HHTheme.footnote)
                                    .foregroundStyle(HHTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .listRowBackground(Color.clear)
                            }
                        }

                        if !filteredEpisodes.isEmpty {
                            Section("Episodes") {
                                ForEach(filteredEpisodes) { episode in
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
                                    let targets = offsets.map { filteredEpisodes[$0] }
                                    for episode in targets {
                                        Task { await memory.deleteEpisode(episode.id) }
                                    }
                                }
                            }
                        }

                        // Inline "possible duplicates" prompt — only
                        // visible when the heuristic finds something
                        // AND the user isn't currently filtering. We
                        // hide during a filter so the suggestion
                        // doesn't get blamed on a search that just
                        // happened to surface two similar rows.
                        if !duplicatePairs.isEmpty && !isFiltering {
                            Section {
                                Button {
                                    showingDuplicates = true
                                } label: {
                                    HStack(spacing: HHTheme.spaceM) {
                                        Image(systemName: "rectangle.stack.badge.minus")
                                            .foregroundStyle(HHTheme.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Possible duplicates")
                                                .font(HHTheme.subheadline.weight(.semibold))
                                                .foregroundStyle(HHTheme.textPrimary)
                                            Text("\(duplicatePairs.count) pair\(duplicatePairs.count == 1 ? "" : "s") look similar — review and merge.")
                                                .font(HHTheme.caption)
                                                .foregroundStyle(HHTheme.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(HHTheme.textSecondary)
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
                    .searchable(
                        text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search memory"
                    )
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
                FactEditorSheet(mode: .create) { fact in
                    Task { await memory.add(fact) }
                }
            }
            .sheet(item: $editingFact) { fact in
                FactEditorSheet(mode: .edit(fact)) { updated in
                    Task { await memory.update(updated) }
                }
            }
            .sheet(isPresented: $showingDuplicates) {
                DuplicateReviewSheet(pairs: duplicatePairs) { keeperID, duplicateID in
                    Task {
                        await memory.mergeDuplicate(
                            keeperID: keeperID,
                            duplicateID: duplicateID
                        )
                    }
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
        // Clear active filters so the target fact is guaranteed to be
        // visible — otherwise a deep link can land "into nothing" when
        // the user happens to be looking at a filtered subset that
        // doesn't include the target.
        searchText = ""
        categoryFilter = nil
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

/// Horizontally-scrolling capsule row for filtering the facts list by
/// category. `nil` selection acts as the "All" pill so the user can
/// always clear the filter without hunting for an "x".
private struct CategoryFilterChips: View {
    @Binding var selection: MemoryFact.Category?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HHTheme.spaceS) {
                chip(label: "All", symbol: "square.grid.2x2",
                     isSelected: selection == nil) {
                    selection = nil
                }
                ForEach(MemoryFact.Category.allCases) { cat in
                    chip(label: cat.label, symbol: cat.symbol,
                         isSelected: selection == cat) {
                        // Toggle off when tapping the active chip —
                        // matches the standard iOS expectation that
                        // re-tapping a selected segment clears it.
                        selection = (selection == cat) ? nil : cat
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func chip(label: String, symbol: String,
                      isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(HHTheme.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isSelected
                        ? HHTheme.accent.opacity(0.18)
                        : Color(.tertiarySystemFill),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? HHTheme.accent : HHTheme.textPrimary)
                .overlay(
                    Capsule()
                        .stroke(isSelected ? HHTheme.accent.opacity(0.45) : Color.clear,
                                lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FactRow: View {
    let fact: MemoryFact
    let onTogglePin: () -> Void
    let onToggleDisabled: () -> Void
    let onEdit: () -> Void

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
        // Tap-anywhere-on-row opens the editor. Using contentShape so
        // the gap between the chip row and the text is also tappable
        // — otherwise small rows feel finicky to hit.
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .swipeActions(edge: .leading) {
            Button(action: onTogglePin) {
                Label(fact.pinned ? "Unpin" : "Pin", systemImage: "pin")
            }
            .tint(HHTheme.accent)
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            .tint(HHTheme.warning)
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

/// Unified create + edit sheet for a `MemoryFact`. The `.create` mode
/// starts empty and constructs a fresh fact on save; `.edit(existing)`
/// pre-populates content + category and preserves all provenance fields
/// (id, source, confidence, timestamps, link to source conversation).
///
/// Replaces the previous `AddFactSheet` which only handled creation —
/// users can now correct typos and miscategorisations directly from the
/// Memory tab without deleting and re-adding the row (which would lose
/// the original `createdAt` and provenance).
private struct FactEditorSheet: View {
    enum Mode {
        case create
        case edit(MemoryFact)

        var titleText: String {
            switch self {
            case .create: return "New fact"
            case .edit:   return "Edit fact"
            }
        }

        var initialContent: String {
            if case .edit(let fact) = self { return fact.content }
            return ""
        }

        var initialCategory: MemoryFact.Category {
            if case .edit(let fact) = self { return fact.category }
            return .other
        }
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let onSave: (MemoryFact) -> Void

    @State private var content: String
    @State private var category: MemoryFact.Category

    init(mode: Mode, onSave: @escaping (MemoryFact) -> Void) {
        self.mode = mode
        self.onSave = onSave
        _content = State(initialValue: mode.initialContent)
        _category = State(initialValue: mode.initialCategory)
    }

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
            .navigationTitle(mode.titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fact: MemoryFact
        switch mode {
        case .create:
            fact = MemoryFact(
                id: UUID(),
                content: trimmed,
                category: category,
                source: .userManual,
                confidence: 1.0,
                createdAt: .now,
                lastUsedAt: nil,
                pinned: false,
                disabled: false
            )
        case .edit(let existing):
            // Preserve every field that isn't the two the user can
            // edit. Provenance (sourceConversationID/sourceMessageID/
            // extractionMethod) stays intact so an edited fact still
            // points back to the chat it came from.
            var copy = existing
            copy.content = trimmed
            copy.category = category
            fact = copy
        }
        onSave(fact)
        dismiss()
    }
}

/// One-shot review surface for the duplicate-fact heuristic. Each
/// detected pair is rendered as two side-by-side cards; tapping
/// "Keep this" on either card deletes the other, leaving the kept
/// row in place with its original provenance. "Keep both" skips the
/// pair without modifying anything — useful when the heuristic
/// surfaced a false positive (semantically distinct facts that just
/// share vocabulary).
///
/// The sheet drives off the SNAPSHOT taken when it opens — pairs
/// don't shift around as the user merges, which prevents the
/// "wait, where did that row go?" jump the user would see if the
/// list re-sorted on every action.
private struct DuplicateReviewSheet: View {
    let pairs: [MemoryService.DuplicatePair]
    let onMerge: (_ keeperID: UUID, _ duplicateID: UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var skipped: Set<UUID> = []
    @State private var resolved: Set<UUID> = []

    private var remaining: [MemoryService.DuplicatePair] {
        pairs.filter { !skipped.contains($0.id) && !resolved.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if remaining.isEmpty {
                    HHEmptyState(
                        icon: "checkmark.seal",
                        title: "All clear",
                        subtitle: "No more duplicate suggestions to review."
                    ) {
                        Button("Done") { dismiss() }
                            .buttonStyle(HHPrimaryButtonStyle())
                    }
                } else {
                    List {
                        ForEach(remaining) { pair in
                            Section {
                                pairCard(pair)
                            } header: {
                                HStack {
                                    Text("Pair")
                                    Spacer()
                                    Text("\(Int((pair.score * 100).rounded()))% match")
                                        .font(HHTheme.caption.monospacedDigit())
                                        .foregroundStyle(HHTheme.textSecondary)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Review duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func pairCard(_ pair: MemoryService.DuplicatePair) -> some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            factCard(pair.primary,
                     keepAction: {
                         onMerge(pair.primary.id, pair.duplicate.id)
                         resolved.insert(pair.id)
                     })
            factCard(pair.duplicate,
                     keepAction: {
                         onMerge(pair.duplicate.id, pair.primary.id)
                         resolved.insert(pair.id)
                     })
            Button {
                skipped.insert(pair.id)
            } label: {
                Label("Keep both", systemImage: "checkmark.circle")
                    .font(HHTheme.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(HHTheme.textSecondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func factCard(_ fact: MemoryFact, keepAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HHTagChip(text: fact.category.label, symbol: fact.category.symbol)
                Spacer()
                Text(fact.createdAt.formatted(.relative(presentation: .named)))
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Text(fact.content)
                .font(HHTheme.body)
            Button("Keep this", action: keepAction)
                .font(HHTheme.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(HHTheme.accent)
                .controlSize(.small)
        }
        .padding(HHTheme.spaceM)
        .background(HHTheme.surface, in: RoundedRectangle(cornerRadius: HHTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: HHTheme.cornerMedium)
                .stroke(HHTheme.stroke, lineWidth: 0.5)
        )
    }
}
