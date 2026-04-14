import SwiftUI

/// Lists every `SystemPromptPreset` the user has configured, lets them
/// switch the active one, add new ones, edit existing custom presets,
/// and delete non-built-in ones.
struct SystemPromptManagerView: View {
    @EnvironmentObject private var settings: SettingsService
    @State private var editingPreset: SystemPromptPreset?
    @State private var showingNewEditor = false

    private var presets: [SystemPromptPreset] {
        settings.current.systemPromptPresets
    }

    private var activeID: UUID {
        settings.current.activeSystemPromptPresetID
    }

    var body: some View {
        List {
            Section {
                ForEach(presets) { preset in
                    Button {
                        activate(preset)
                    } label: {
                        row(for: preset)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !preset.isBuiltIn {
                            Button(role: .destructive) {
                                delete(preset)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        Button {
                            editingPreset = preset
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(HHTheme.accent)
                    }
                }
            } footer: {
                Text("The active preset seeds every new conversation's system prompt. Built-in presets can be edited but not deleted.")
            }
        }
        .navigationTitle("System prompts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New preset")
            }
        }
        .sheet(isPresented: $showingNewEditor) {
            PresetEditor(mode: .create) { newPreset in
                Task { await save(newPreset: newPreset) }
            }
        }
        .sheet(item: $editingPreset) { preset in
            PresetEditor(mode: .edit(preset)) { updated in
                Task { await save(edited: updated) }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for preset: SystemPromptPreset) -> some View {
        HStack(alignment: .top, spacing: HHTheme.spaceM) {
            Image(systemName: preset.id == activeID ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(preset.id == activeID ? HHTheme.accent : HHTheme.textSecondary)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: HHTheme.spaceS) {
                    Text(preset.name)
                        .font(HHTheme.headline)
                        .foregroundStyle(HHTheme.textPrimary)
                    if preset.isBuiltIn {
                        Text("Built-in")
                            .font(HHTheme.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(HHTheme.accentSoft, in: Capsule())
                            .foregroundStyle(HHTheme.accent)
                    }
                }
                Text(preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(HHTheme.footnote)
                    .foregroundStyle(HHTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func activate(_ preset: SystemPromptPreset) {
        guard preset.id != activeID else { return }
        HHHaptics.selection(enabled: settings.current.haptics)
        Task { await settings.set(\.activeSystemPromptPresetID, to: preset.id) }
    }

    private func delete(_ preset: SystemPromptPreset) {
        guard !preset.isBuiltIn else { return }
        var next = settings.current.systemPromptPresets
        next.removeAll { $0.id == preset.id }
        Task {
            var updated = settings.current
            updated.systemPromptPresets = next
            if updated.activeSystemPromptPresetID == preset.id {
                updated.activeSystemPromptPresetID = SystemPromptPreset.defaultBuiltInID
            }
            await settings.update(updated)
        }
    }

    private func save(newPreset: SystemPromptPreset) async {
        var updated = settings.current
        updated.systemPromptPresets.append(newPreset)
        await settings.update(updated)
    }

    private func save(edited: SystemPromptPreset) async {
        var updated = settings.current
        guard let idx = updated.systemPromptPresets.firstIndex(where: { $0.id == edited.id }) else { return }
        // Preserve isBuiltIn flag — the editor never exposes it.
        var merged = edited
        merged.isBuiltIn = updated.systemPromptPresets[idx].isBuiltIn
        updated.systemPromptPresets[idx] = merged
        await settings.update(updated)
    }
}

// MARK: - Editor

private struct PresetEditor: View {
    enum Mode {
        case create
        case edit(SystemPromptPreset)
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let onSave: (SystemPromptPreset) -> Void

    @State private var name: String = ""
    @State private var prompt: String = ""

    private var title: String {
        switch mode {
        case .create: return "New preset"
        case .edit:   return "Edit preset"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Coder, Czech assistant", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("System prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 220)
                        .font(HHTheme.body)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedPrompt = prompt
                        switch mode {
                        case .create:
                            onSave(SystemPromptPreset(
                                id: UUID(),
                                name: trimmedName,
                                prompt: trimmedPrompt,
                                isBuiltIn: false
                            ))
                        case .edit(let preset):
                            onSave(SystemPromptPreset(
                                id: preset.id,
                                name: trimmedName,
                                prompt: trimmedPrompt,
                                isBuiltIn: preset.isBuiltIn
                            ))
                        }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if case .edit(let preset) = mode {
                    name = preset.name
                    prompt = preset.prompt
                }
            }
        }
    }
}
