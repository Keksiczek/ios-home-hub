import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var memory: MemoryService
    @EnvironmentObject private var settings: SettingsService
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if memory.facts.isEmpty && memory.candidates.isEmpty {
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
                            Section("Proposed") {
                                ForEach(memory.candidates) { candidate in
                                    CandidateRow(candidate: candidate) {
                                        Task { await memory.accept(candidate) }
                                    } onReject: {
                                        memory.reject(candidateID: candidate.id)
                                    }
                                }
                            }
                        }

                        Section("Remembered") {
                            ForEach(memory.facts) { fact in
                                FactRow(fact: fact,
                                        onTogglePin: {
                                            Task { await memory.setPinned(!fact.pinned, for: fact.id) }
                                        },
                                        onToggleDisabled: {
                                            Task { await memory.setDisabled(!fact.disabled, for: fact.id) }
                                        })
                            }
                            .onDelete { offsets in
                                let targets = offsets.map { memory.facts[$0] }
                                for fact in targets {
                                    Task { await memory.delete(fact.id) }
                                }
                            }
                        }

                        Section {
                            Button(role: .destructive) {
                                Task { await memory.clearAll() }
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
            .overlay(alignment: .top) {
                if !settings.current.memoryEnabled {
                    MemoryDisabledBanner()
                }
            }
        }
    }
}

private struct CandidateRow: View {
    let candidate: MemoryCandidate
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceS) {
            HStack {
                HHTagChip(text: candidate.category.label,
                          symbol: candidate.category.symbol)
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
