import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsService
    @EnvironmentObject private var personalization: PersonalizationService
    @EnvironmentObject private var memory: MemoryService
    @EnvironmentObject private var onboarding: OnboardingService
    @EnvironmentObject private var runtime: RuntimeManager

    /// Cached snapshot of `SkillManager.availabilitySnapshot()` so the
    /// row UI can render synchronously while the Settings screen is on
    /// screen. Refreshed on appear and after the user comes back from
    /// the iOS Settings app.
    @State private var toolAvailability: [String: SkillAvailability] = [:]

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                assistantSection
                promptConfigSection
                languageSection
                toolsSection
                memorySection
                generationSection
                appearanceSection
                privacySection
                aboutSection
                developerSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarMenuButton()
                }
            }
            // Refresh the cached availability snapshot every time the
            // Settings screen comes into focus — covers the "user
            // granted Calendar access, tapped back to the app" case.
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )) { _ in
                Task { await refreshToolAvailability() }
            }
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section("You") {
            NavigationLink("Name & details") {
                ProfileEditor(profile: personalization.userProfile) { updated in
                    Task { await personalization.update(user: updated) }
                }
            }
        }
    }

    // MARK: - Assistant

    private var assistantSection: some View {
        Section("Assistant") {
            TextField("Name", text: Binding(
                get: { personalization.assistantProfile.name },
                set: { newValue in
                    var a = personalization.assistantProfile
                    a.name = newValue
                    Task { await personalization.update(assistant: a) }
                }
            ))
            NavigationLink("System prompts") {
                SystemPromptManagerView()
            }
        }
    }

    // MARK: - Prompt configuration

    private var promptConfigSection: some View {
        Section {
            Text("Safety")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
            Toggle("Hard rules", isOn: Binding(
                get: { settings.current.guardrailsConfig.hardRulesEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.hardRulesEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            Toggle("Privacy guardrail", isOn: Binding(
                get: { settings.current.guardrailsConfig.privacyGuardrailEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.privacyGuardrailEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))

            Text("Context layers")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
                .padding(.top, 8)
            Toggle("Remembered facts", isOn: Binding(
                get: { settings.current.guardrailsConfig.factsEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.factsEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            Toggle("Recent episodes", isOn: Binding(
                get: { settings.current.guardrailsConfig.episodesEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.episodesEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            Toggle("File excerpts", isOn: Binding(
                get: { settings.current.guardrailsConfig.fileExcerptsEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.fileExcerptsEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            Toggle("Skill instructions", isOn: Binding(
                get: { settings.current.guardrailsConfig.skillInstructionsEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.skillInstructionsEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
        } header: {
            Text("Prompt configuration")
        } footer: {
            Text("Customize which safety rules and context layers are included in the system prompt.")
        }
    }

    // MARK: - Language & style

    private var languageSection: some View {
        Section {
            Picker("Language", selection: Binding(
                get: { settings.current.language },
                set: { newValue in Task { await settings.set(\.language, to: newValue) } }
            )) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.label).tag(lang)
                }
            }

            Picker("Answer length", selection: Binding(
                get: { settings.current.answerLength },
                set: { newValue in Task { await settings.set(\.answerLength, to: newValue) } }
            )) {
                ForEach(AnswerLength.allCases) { length in
                    Text(length.label).tag(length)
                }
            }

            TextField("Location hint", text: Binding(
                get: { settings.current.locationHint },
                set: { newValue in Task { await settings.set(\.locationHint, to: newValue) } }
            ))
            .textInputAutocapitalization(.words)
        } header: {
            Text("Language & style")
        } footer: {
            Text("Language is enforced in the system prompt — the assistant replies in the chosen language even if you type in another. Location is injected so the model answers local-context questions correctly.")
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        Section {
            ForEach(Array(AppSettings.defaultEnabledTools).sorted(), id: \.self) { toolName in
                ToolRow(
                    toolName: toolName,
                    isEnabled: settings.current.enabledTools.contains(toolName),
                    availability: toolAvailability[toolName] ?? .enabled,
                    onToggle: { enabled in
                        var current = settings.current.enabledTools
                        if enabled { current.insert(toolName) } else { current.remove(toolName) }
                        Task { await settings.set(\.enabledTools, to: current) }
                    },
                    onGrantPermission: { openAppSettings() }
                )
            }
        } header: {
            Text("Tools")
        } footer: {
            Text("Only enabled tools are offered to the assistant. Math goes through Calculator, calendar questions through Calendar. Disabled tools are refused even if the model tries to call them.")
        }
        .task { await refreshToolAvailability() }
    }

    private func refreshToolAvailability() async {
        let snapshot = await SkillManager.shared.availabilitySnapshot()
        var dict: [String: SkillAvailability] = [:]
        for entry in snapshot { dict[entry.name] = entry.availability }
        toolAvailability = dict
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Memory

    private var memorySection: some View {
        Section {
            NavigationLink("My memory") {
                UserMemoryView()
            }

            Toggle("Enable retrieval memory", isOn: Binding(
                get: { settings.current.memoryEnabled },
                set: { newValue in
                    Task { await settings.set(\.memoryEnabled, to: newValue) }
                }
            ))
            Toggle("Auto-propose facts from chats", isOn: Binding(
                get: { settings.current.autoExtractMemory },
                set: { newValue in
                    Task { await settings.set(\.autoExtractMemory, to: newValue) }
                }
            ))
            .disabled(!settings.current.memoryEnabled)

            Button(role: .destructive) {
                Task { await memory.clearAll() }
            } label: {
                Text("Clear retrieval memory")
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("Two layers: \"My memory\" holds facts you type yourself. \"Retrieval memory\" captures facts the assistant proposes after each chat — nothing is saved unless you accept it. Both stay on this device.")
        }
    }

    // MARK: - Generation

    private var generationSection: some View {
        Section {
            Toggle("Stream responses", isOn: Binding(
                get: { settings.current.streamingEnabled },
                set: { newValue in Task { await settings.set(\.streamingEnabled, to: newValue) } }
            ))

            HStack {
                Text("Max response tokens")
                Spacer()
                Text("\(settings.current.maxResponseTokens)")
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.current.maxResponseTokens) },
                    set: { newValue in Task { await settings.set(\.maxResponseTokens, to: Int(newValue)) } }
                ),
                in: 128...2048, step: 64
            )

            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.2f", settings.current.temperature))
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { settings.current.temperature },
                    set: { newValue in Task { await settings.set(\.temperature, to: newValue) } }
                ),
                in: 0.0...1.5, step: 0.05
            )

            HStack {
                Text("Top-p")
                Spacer()
                Text(String(format: "%.2f", settings.current.topP))
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { settings.current.topP },
                    set: { newValue in Task { await settings.set(\.topP, to: newValue) } }
                ),
                in: 0.1...1.0, step: 0.05
            )

            HStack {
                Text("Top-k")
                Spacer()
                Text("\(settings.current.topK)")
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.current.topK) },
                    set: { newValue in Task { await settings.set(\.topK, to: Int(newValue)) } }
                ),
                in: 0...100, step: 5
            )

            HStack {
                Text("Min-p")
                Spacer()
                Text(String(format: "%.2f", settings.current.minP))
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { settings.current.minP },
                    set: { newValue in Task { await settings.set(\.minP, to: newValue) } }
                ),
                in: 0.0...0.3, step: 0.01
            )

            HStack {
                Text("Repeat penalty")
                Spacer()
                Text(String(format: "%.2f", settings.current.repeatPenalty))
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { settings.current.repeatPenalty },
                    set: { newValue in Task { await settings.set(\.repeatPenalty, to: newValue) } }
                ),
                in: 1.0...1.5, step: 0.05
            )

            // Display preference — kept at the bottom of the section so
            // the generation knobs (stream, tokens, temperature) stay
            // grouped and this reads as a "show this extra info" toggle.
            Toggle("Show token usage", isOn: Binding(
                get: { settings.current.showTokenUsage },
                set: { newValue in Task { await settings.set(\.showTokenUsage, to: newValue) } }
            ))
        } header: {
            Text("Generation")
        } footer: {
            Text("Higher temperature is more creative but less predictable. 0.6–0.8 is a good range for most tasks. Repeat penalty 1.1 and Min-p 0.05 are sensible defaults that keep small models from looping or emitting garbage characters.")
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: Binding(
                get: { settings.current.theme },
                set: { newValue in Task { await settings.set(\.theme, to: newValue) } }
            )) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            Toggle("Haptics", isOn: Binding(
                get: { settings.current.haptics },
                set: { newValue in
                    // Fire haptic on the new value so the user feels the
                    // toggle turning on (or gets silence when turning off).
                    HHHaptics.impact(.medium, enabled: newValue)
                    Task { await settings.set(\.haptics, to: newValue) }
                }
            ))
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            NavigationLink("Privacy & data") {
                PrivacyView()
            }
            Button("Restart onboarding") {
                Task { await onboarding.reset() }
            }
        } header: {
            Text("Privacy")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "1.0 (skeleton)")
            LabeledContent("Runtime", value: runtime.runtime.identifier)
            LabeledContent("Runtime state", value: runtimeStateLabel)
        } header: {
            Text("About")
        }
    }

    private var runtimeStateLabel: String {
        switch runtime.state {
        case .idle:            return "Idle"
        case .loading(let id): return "Loading \(id)"
        case .ready(let id):   return "Ready — \(id)"
        case .failed:          return "Failed (see Developer Diagnostics)"
        }
    }

    // MARK: - Developer

    private var developerSection: some View {
        Section {
            NavigationLink("Runtime Diagnostics") {
                DeveloperDiagnosticsView()
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Live runtime state, build / backend info, model file integrity, telemetry log, and model reset — visible on device without Xcode.")
        }
    }
}

private struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: UserProfile
    let onSave: (UserProfile) -> Void

    var body: some View {
        Form {
            Section("Name") {
                TextField("Your name", text: $profile.displayName)
                TextField("Pronouns", text: Binding(
                    get: { profile.pronouns ?? "" },
                    set: { profile.pronouns = $0.isEmpty ? nil : $0 }
                ))
            }
            Section("Work") {
                TextField("Occupation", text: Binding(
                    get: { profile.occupation ?? "" },
                    set: { profile.occupation = $0.isEmpty ? nil : $0 }
                ))
                TextField("Current focus", text: Binding(
                    get: { profile.workingContext ?? "" },
                    set: { profile.workingContext = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                    .lineLimit(2...4)
            }
            Section("Interests") {
                TextField("Comma-separated", text: Binding(
                    get: { profile.interests.joined(separator: ", ") },
                    set: { newValue in
                        profile.interests = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ), axis: .vertical)
                    .lineLimit(2...4)
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    onSave(profile)
                    dismiss()
                }
            }
        }
    }
}

/// Single-tool row in the Settings → Tools section.
///
/// Shows:
///   * the tool name,
///   * a status line tuned to the skill's `availability` (Enabled,
///     needs permission, or unavailable),
///   * a toggle that flips the user allow-list,
///   * a "Grant…" button on permission-missing rows that bounces the
///     user to the iOS Settings app (we don't own the prompt for
///     most permissions — the tool will trigger it on first run).
private struct ToolRow: View {
    let toolName: String
    let isEnabled: Bool
    let availability: SkillAvailability
    let onToggle: (Bool) -> Void
    let onGrantPermission: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(
                    get: { isEnabled },
                    set: onToggle
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(toolName)
                        Text(statusLine)
                            .font(HHTheme.caption)
                            .foregroundStyle(statusColor)
                    }
                }
            }

            if case .permission = availability {
                Button("Grant permission in Settings", action: onGrantPermission)
                    .font(HHTheme.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .padding(.leading, 0)
            }
        }
    }

    private var statusLine: String {
        switch availability {
        case .enabled:                 return "Ready"
        case .unavailable(let reason): return "Unavailable — \(reason)"
        case .permission(let prompt):  return "Needs permission — \(prompt)"
        }
    }

    private var statusColor: Color {
        switch availability {
        case .enabled:     return HHTheme.textSecondary
        case .unavailable: return HHTheme.danger
        case .permission:  return HHTheme.warning
        }
    }
}

private struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HHTheme.spaceL) {
                Text("HomeHub is built to be boring on purpose.")
                    .font(HHTheme.title2)
                Text("No account. No server. No telemetry. No analytics. No ads.")
                    .font(HHTheme.body)
                    .foregroundStyle(HHTheme.textSecondary)

                HHCard {
                    VStack(alignment: .leading, spacing: HHTheme.spaceM) {
                        HHFeatureRow(icon: "externaldrive", title: "Where your data lives",
                                     text: "Inside the app's sandbox on this device. It's backed up with your device backups and nowhere else.")
                        HHFeatureRow(icon: "network.slash", title: "Network",
                                     text: "The app only reaches the network to download a model you've explicitly asked for.")
                        HHFeatureRow(icon: "trash", title: "Deletion",
                                     text: "Clearing memory, deleting chats, or removing models is immediate and permanent.")
                    }
                }
            }
            .padding(HHTheme.spaceL)
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
