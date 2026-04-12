import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsService
    @EnvironmentObject private var personalization: PersonalizationService
    @EnvironmentObject private var memory: MemoryService
    @EnvironmentObject private var onboarding: OnboardingService

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                assistantSection
                memorySection
                generationSection
                appearanceSection
                privacySection
                aboutSection
            }
            .navigationTitle("Settings")
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
            Picker("Response style", selection: Binding(
                get: { personalization.userProfile.preferredResponseStyle },
                set: { newValue in
                    var user = personalization.userProfile
                    user.preferredResponseStyle = newValue
                    Task { await personalization.update(user: user) }
                }
            )) {
                ForEach(ResponseStyle.allCases) { style in
                    Text(style.label).tag(style)
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
            Picker("Tone", selection: Binding(
                get: { personalization.assistantProfile.tone },
                set: { newValue in
                    var a = personalization.assistantProfile
                    a.tone = newValue
                    Task { await personalization.update(assistant: a) }
                }
            )) {
                ForEach(AssistantTone.allCases) { tone in
                    Text(tone.label).tag(tone)
                }
            }
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        Section {
            Toggle("Enable memory", isOn: Binding(
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
                Text("Clear all memory")
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("The assistant can recall facts you've approved. Nothing is saved unless you accept it. Memory never leaves this device.")
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
        } header: {
            Text("Generation")
        } footer: {
            Text("Higher temperature is more creative but less predictable. 0.6–0.8 is a good range for most tasks.")
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
            LabeledContent("Runtime", value: "llama.cpp")
        } header: {
            Text("About")
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
