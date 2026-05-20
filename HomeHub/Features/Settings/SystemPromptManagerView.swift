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

    private var guardrailsStatus: String {
        let config = settings.current.guardrailsConfig
        let enabled = [config.hardRulesEnabled, config.privacyGuardrailEnabled].filter { $0 }.count
        if enabled == 2 { return "Bezpečný režim ✓" }
        if enabled == 0 { return "Bez omezení" }
        return "Smíšené"
    }

    private var contexLayersStatus: String {
        let config = settings.current.guardrailsConfig
        let enabled = [config.factsEnabled, config.episodesEnabled, config.fileExcerptsEnabled, config.skillInstructionsEnabled].filter { $0 }.count
        if enabled == 4 { return "Plný kontext ✓" }
        if enabled == 0 { return "Minimální" }
        return "\(enabled)/4 vrstev"
    }

    var body: some View {
        List {
            Section("Aktuální konfigurace") {
                LabeledContent("Aktivní preset") {
                    Text(settings.current.activeSystemPromptPreset.name)
                        .foregroundStyle(HHTheme.accent)
                        .font(.subheadline)
                }
                LabeledContent("Bezpečnost", value: guardrailsStatus)
                LabeledContent("Kontext", value: contexLayersStatus)
            }

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
                                Label("Zobrazit", systemImage: "eye")
                            }
                            .tint(HHTheme.accent)
                        } else {
                            Button(role: .destructive) {
                                pendingDeletion = preset
                            } label: {
                                Label("Smazat", systemImage: "trash")
                            }
                            Button {
                                editingPreset = preset
                            } label: {
                                Label("Upravit", systemImage: "pencil")
                            }
                            .tint(HHTheme.accent)
                        }
                    }
                }
            } footer: {
                Text("Aktivní preset se vloží jako systémový prompt do každé nové konverzace. Vestavěné presety jsou jen pro čtení, aby šlo výchozí chování asistenta vždy obnovit.")
            }
        }
        .navigationTitle("Systémové prompty")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Nový preset")
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
            "Smazat preset \(pendingDeletion?.name ?? "")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { preset in
            Button("Smazat", role: .destructive) {
                delete(preset)
                pendingDeletion = nil
            }
            Button("Zrušit", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("Tento preset bude odebrán. Kdykoli ho můžeš znovu vytvořit.")
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
                        Text("Vestavěný")
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
    @State private var icon: String = PresetEditor.iconOptions.first ?? "sparkles"
    @State private var colorHex: String = PresetEditor.colorOptions.first ?? "007AFF"

    /// Curated icon set offered for custom personas. SF Symbols that
    /// read well at small sizes and cover the common assistant roles.
    static let iconOptions: [String] = [
        "sparkles", "chevron.left.forwardslash.chevron.right", "paintbrush.pointed.fill",
        "character.book.closed.fill", "brain.head.profile", "graduationcap.fill",
        "briefcase.fill", "lightbulb.fill", "heart.fill", "globe", "function", "wand.and.stars"
    ]

    /// Hex palette mirrors the iOS system colours used by the built-in
    /// presets so custom personas sit visually alongside them.
    static let colorOptions: [String] = [
        "007AFF", "AF52DE", "FF9500", "34C759", "FF2D55", "5856D6", "FF3B30", "00C7BE"
    ]

    private var title: String {
        switch mode {
        case .create: return "Nový preset"
        case .edit:   return "Upravit preset"
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
                Section("Název") {
                    TextField("např. Programátor, Český asistent", text: $name)
                        .textInputAutocapitalization(.words)
                        .disabled(mode.isReadOnly)
                }
                Section("Vzhled") {
                    iconPicker
                    colorPicker
                }
                Section("Systémový prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 220)
                        .font(HHTheme.body)
                        .disabled(mode.isReadOnly)
                        .foregroundStyle(mode.isReadOnly ? HHTheme.textSecondary : HHTheme.textPrimary)
                }
                if duplicateName && !mode.isReadOnly {
                    Section {
                        Label("Jiný preset už tento název používá.", systemImage: "exclamationmark.triangle")
                            .font(HHTheme.footnote)
                            .foregroundStyle(HHTheme.warning)
                    }
                }
                if case .view = mode {
                    Section {
                        Label("Vestavěný preset — jen pro čtení.", systemImage: "lock")
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
                        Button("Hotovo") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Zrušit") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Uložit") {
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
                    if let i = preset.icon { icon = i }
                    if let c = preset.colorHex { colorHex = c }
                }
            }
        }
    }

    // MARK: - Appearance pickers

    private var selectedColor: Color {
        Color(hex: colorHex) ?? .blue
    }

    @ViewBuilder
    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceS) {
            Text("Ikona")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HHTheme.spaceM) {
                    ForEach(Self.iconOptions, id: \.self) { option in
                        let isSelected = option == icon
                        Image(systemName: option)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : selectedColor)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle().fill(isSelected ? selectedColor : selectedColor.opacity(0.12))
                            )
                            .overlay(Circle().stroke(selectedColor.opacity(isSelected ? 0 : 0.25), lineWidth: 1))
                            .contentShape(Circle())
                            .onTapGesture { if !mode.isReadOnly { icon = option } }
                            .accessibilityLabel(isSelected ? "Vybraná ikona" : "Ikona")
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .disabled(mode.isReadOnly)
    }

    @ViewBuilder
    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceS) {
            Text("Barva")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HHTheme.spaceM) {
                    ForEach(Self.colorOptions, id: \.self) { option in
                        let optionColor = Color(hex: option) ?? .blue
                        let isSelected = option == colorHex
                        Circle()
                            .fill(optionColor)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .stroke(HHTheme.textPrimary, lineWidth: isSelected ? 2 : 0)
                                    .padding(2)
                            )
                            .contentShape(Circle())
                            .onTapGesture { if !mode.isReadOnly { colorHex = option } }
                            .accessibilityLabel(isSelected ? "Vybraná barva" : "Barva")
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .disabled(mode.isReadOnly)
    }

    private func commit() {
        switch mode {
        case .create:
            onSave(SystemPromptPreset(
                id: UUID(),
                name: trimmedName,
                prompt: prompt,
                isBuiltIn: false,
                icon: icon,
                colorHex: colorHex,
                shortDescription: nil
            ))
        case .edit(let preset):
            onSave(SystemPromptPreset(
                id: preset.id,
                name: trimmedName,
                prompt: prompt,
                isBuiltIn: false,
                icon: icon,
                colorHex: colorHex,
                shortDescription: preset.shortDescription
            ))
        case .view:
            break
        }
    }
}
