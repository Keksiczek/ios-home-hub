import SwiftUI

/// Lists every `SystemPromptPreset` the user has configured, lets them
/// switch the active one, add new custom ones, and edit / delete
/// existing custom presets.
///
/// Built-in presets are read-only — they can be activated and viewed
/// but never edited or deleted. This keeps the default assistant
/// behaviour recoverable: the user always has a known-good fallback.
struct SystemPromptManagerView: View {
    @EnvironmentObject private var settings: SettingsService
    @State private var editingPreset: SystemPromptPreset?
    @State private var viewingPreset: SystemPromptPreset?
    @State private var pendingDeletion: SystemPromptPreset?
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
                    .listRowBackground(
                        preset.id == activeID
                            ? HHTheme.accentSoft
                            : Color(.secondarySystemGroupedBackground)
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if preset.isBuiltIn {
                            Button {
                                viewingPreset = preset
                            } label: {
                                Label("View", systemImage: "eye")
                            }
                            .tint(HHTheme.accent)
                        } else {
                            Button(role: .destructive) {
                                pendingDeletion = preset
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editingPreset = preset
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(HHTheme.accent)
                        }
                    }
                }
            } footer: {
                Text("The active preset seeds every new conversation's system prompt. Built-in presets are read-only so the default assistant behaviour stays recoverable.")
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
            PresetEditor(
                mode: .create,
                existingNames: presets.map { $0.name }
            ) { newPreset in
                Task { await save(newPreset: newPreset) }
            }
        }
        .sheet(item: $editingPreset) { preset in
            PresetEditor(
                mode: .edit(preset),
                existingNames: presets.filter { $0.id != preset.id }.map { $0.name }
            ) { updated in
                Task { await save(edited: updated) }
            }
        }
        .sheet(item: $viewingPreset) { preset in
            PresetEditor(
                mode: .view(preset),
                existingNames: []
            ) { _ in }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { preset in
            Button("Delete", role: .destructive) {
                delete(preset)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("This preset will be removed. You can always create it again later.")
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
        Task {
            var updated = settings.current
            updated.systemPromptPresets.removeAll { $0.id == preset.id }
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
        // Never allow the built-in flag to be flipped from the editor.
        guard !updated.systemPromptPresets[idx].isBuiltIn else { return }
        var merged = edited
        merged.isBuiltIn = false
        updated.systemPromptPresets[idx] = merged
        await settings.update(updated)
    }
}

// MARK: - Editor

private struct PresetEditor: View {
    enum Mode {
        case create
        case edit(SystemPromptPreset)
        case view(SystemPromptPreset)

        var isReadOnly: Bool {
            if case .view = self { return true }
            return false
        }
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    /// Names of other presets — used for duplicate-name validation on
    /// create/edit. Pass an empty array when not relevant (e.g. view).
    let existingNames: [String]
    let onSave: (SystemPromptPreset) -> Void

    @State private var name: String = ""
    @State private var prompt: String = ""

    private var title: String {
        switch mode {
        case .create: return "New preset"
        case .edit:   return "Edit preset"
        case .view:   return "Preset"
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var duplicateName: Bool {
        let needle = trimmedName.lowercased()
        return existingNames.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedPrompt.isEmpty && !duplicateName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Coder, Czech assistant", text: $name)
                        .textInputAutocapitalization(.words)
                        .disabled(mode.isReadOnly)
                }
                Section("System prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 220)
                        .font(HHTheme.body)
                        .disabled(mode.isReadOnly)
                        .foregroundStyle(mode.isReadOnly ? HHTheme.textSecondary : HHTheme.textPrimary)
                }
                if duplicateName && !mode.isReadOnly {
                    Section {
                        Label("Another preset already uses this name.", systemImage: "exclamationmark.triangle")
                            .font(HHTheme.footnote)
                            .foregroundStyle(HHTheme.warning)
                    }
                }
                if case .view = mode {
                    Section {
                        Label("Built-in preset — read-only.", systemImage: "lock")
                            .font(HHTheme.footnote)
                            .foregroundStyle(HHTheme.textSecondary)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if mode.isReadOnly {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") {
                            commit()
                            dismiss()
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear {
                switch mode {
                case .create:
                    break
                case .edit(let preset), .view(let preset):
                    name = preset.name
                    prompt = preset.prompt
                }
            }
        }
    }

    private func commit() {
        switch mode {
        case .create:
            onSave(SystemPromptPreset(
                id: UUID(),
                name: trimmedName,
                prompt: prompt,
                isBuiltIn: false
            ))
        case .edit(let preset):
            onSave(SystemPromptPreset(
                id: preset.id,
                name: trimmedName,
                prompt: prompt,
                isBuiltIn: false
            ))
        case .view:
            break
        }
    }
}
