import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsService
    @EnvironmentObject private var personalization: PersonalizationService
    @EnvironmentObject private var memory: MemoryService
    @EnvironmentObject private var onboarding: OnboardingService
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var appState: AppState
    /// Needed for the post-token-save retry surface: we scan the
    /// catalog for `requiresAuth` models stuck in `.failed(reason:)`
    /// and offer a one-tap retry without forcing the user to switch
    /// tabs back to Models.
    @EnvironmentObject private var modelCatalog: ModelCatalogService
    @EnvironmentObject private var modelDownloads: ModelDownloadService
    /// Foreground re-validation lives on the container; this is how
    /// the live token status surfaces into the Settings UI without
    /// the row needing to re-poll the network on every appearance.
    @EnvironmentObject private var container: AppContainer

    /// Cached snapshot of `SkillManager.availabilitySnapshot()` so the
    /// row UI can render synchronously while the Settings screen is on
    /// screen. Refreshed on appear and after the user comes back from
    /// the iOS Settings app.
    @State private var toolAvailability: [String: SkillAvailability] = [:]

    /// Drives the "Restart onboarding" destructive confirmation alert.
    /// The action wipes personalization (user name, assistant style)
    /// and flips the app back to the onboarding flow — irreversible
    /// from the user's perspective once they tap through. Previously
    /// fired immediately on button tap with no guard at all; the
    /// alert is the cheapest correct fix until we wire snapshot/undo.
    @State private var showRestartOnboardingConfirm: Bool = false

    /// Mirror of the persisted HF token. Loaded from Keychain when the
    /// section appears; written back on Save. Kept as a separate
    /// `@State` (rather than reading the Keychain on every render)
    /// because Keychain calls block briefly and SwiftUI re-renders the
    /// Form on each unrelated state change.
    @State private var hfTokenDraft: String = ""
    @State private var hfTokenStored: Bool = false
    @State private var hfTokenSaveMessage: String?
    /// Tracks the async whoami probe so the UI can disable the Save
    /// button while it's running and surface the result inline.
    @State private var hfTokenValidating: Bool = false
    /// Result of the last whoami probe — drives the badge colour
    /// (green = authenticated, red = rejected, grey = pending).
    @State private var hfTokenLastValidation: HuggingFaceAPIClient.TokenValidation?
    /// Persisted "last verified at" snapshot, surfaced as
    /// "Naposledy ověřeno před X dny — username" so the user can spot
    /// stale state (e.g. token rotated 6 months ago) without re-running
    /// the probe.
    @State private var hfTokenLastVerification: (username: String, at: Date)?
    /// Set by the "Stáhnout všech N modelů" button. Non-nil triggers
    /// the confirmation alert; nil dismisses it. The alert reads the
    /// snapshot rather than re-querying the catalog so the count and
    /// size shown in the prompt match exactly what the user tapped.
    @State private var bulkRetryTarget: [LocalModel]?

    /// Route enum for path-based navigation. Lets a deep link push
    /// the right destination from outside without the user having
    /// to tap through Settings → Developer → Knowledge Base.
    private enum Route: Hashable {
        case knowledgeBase
    }
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                DisclosureGroup {
                    profileSection
                    assistantSection
                    languageSection
                } label: {
                    Label("Assistant & Identity", systemImage: "person.circle.fill")
                        .font(HHTheme.subheadline.weight(.semibold))
                }

                DisclosureGroup {
                    toolsSection
                    memorySection
                } label: {
                    Label("Intelligence & Skills", systemImage: "cpu.fill")
                        .font(HHTheme.subheadline.weight(.semibold))
                }

                DisclosureGroup {
                    generationSection
                } label: {
                    Label("Generation Engine", systemImage: "bolt.fill")
                        .font(HHTheme.subheadline.weight(.semibold))
                }

                DisclosureGroup {
                    appearanceSection
                    privacySection
                    huggingFaceSection
                } label: {
                    Label("App Experience", systemImage: "paintpalette.fill")
                        .font(HHTheme.subheadline.weight(.semibold))
                }

                DisclosureGroup {
                    aboutSection
                    developerSection
                } label: {
                    Label("System & Info", systemImage: "info.circle.fill")
                        .font(HHTheme.subheadline.weight(.semibold))
                }
            }
            .navigationTitle("Nastavení")
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
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .knowledgeBase:
                    KnowledgeBaseDebugView()
                }
            }
            // Document deep link: push KB Debug view onto the
            // Settings stack. KnowledgeBaseDebugView itself then
            // consumes `appState.pendingDeepLink` to scroll to the
            // matching row. We DON'T clear the link here — the KB
            // view is the authoritative consumer for documents.
            .onChange(of: appState.pendingDeepLink) { _, newValue in
                guard case .document = newValue else { return }
                if path.last != .knowledgeBase {
                    path.append(.knowledgeBase)
                }
            }
            .task {
                if case .document = appState.pendingDeepLink,
                   appState.selectedTab == .settings,
                   path.last != .knowledgeBase {
                    path.append(.knowledgeBase)
                }
            }
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section("Ty") {
            NavigationLink("Jméno a údaje") {
                ProfileEditor(profile: personalization.userProfile) { updated in
                    Task { await personalization.update(user: updated) }
                }
            }
        }
    }

    // MARK: - Assistant

    private var assistantSection: some View {
        Section {
            TextField("Jméno asistenta", text: Binding<String>(
                get: { personalization.assistantProfile.name },
                set: { newValue in
                    var a = personalization.assistantProfile
                    a.name = newValue
                    Task { await personalization.update(assistant: a) }
                }
            ))
            Picker("Tón", selection: Binding<AssistantTone>(
                get: { personalization.assistantProfile.tone },
                set: { newValue in
                    var a = personalization.assistantProfile
                    a.tone = newValue
                    Task { await personalization.update(assistant: a) }
                }
            )) {
                ForEach(AssistantTone.allCases) { tone in
                    // .tag must be on the direct ForEach child (VStack), not
                    // on a nested Text — otherwise SwiftUI Picker can't match
                    // the selection and logs "selection X is invalid".
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tone.label)
                        Text(tone.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(tone)
                }
            }
            NavigationLink("Systémové prompty") {
                SystemPromptManagerView()
            }
            LabeledContent("Aktivní preset") {
                Text(settings.current.activeSystemPromptPreset.name)
                    .foregroundStyle(HHTheme.accent)
                    .font(HHTheme.caption)
            }

            Divider()
                .padding(.vertical, 4)

            Text("Bezpečnost")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
            Toggle("Všechny pojistky", isOn: Binding(
                get: { settings.current.guardrailsConfig.hardRulesEnabled && settings.current.guardrailsConfig.privacyGuardrailEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.hardRulesEnabled = newValue
                    config.privacyGuardrailEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            .bold()
            Toggle("Tvrdá pravidla", isOn: Binding(
                get: { settings.current.guardrailsConfig.hardRulesEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.hardRulesEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            .padding(.leading, 12)
            Toggle("Ochrana soukromí", isOn: Binding(
                get: { settings.current.guardrailsConfig.privacyGuardrailEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.privacyGuardrailEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            .padding(.leading, 12)

            Text("Kontextové vrstvy")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
                .padding(.top, 8)
            Toggle("Všechny vrstvy", isOn: Binding(
                get: { settings.current.guardrailsConfig.factsEnabled && settings.current.guardrailsConfig.episodesEnabled && settings.current.guardrailsConfig.fileExcerptsEnabled && settings.current.guardrailsConfig.skillInstructionsEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.factsEnabled = newValue
                    config.episodesEnabled = newValue
                    config.fileExcerptsEnabled = newValue
                    config.skillInstructionsEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            .bold()
            Toggle("Zapamatovaná fakta", isOn: Binding(
                get: { settings.current.guardrailsConfig.factsEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.factsEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            .padding(.leading, 12)
            Toggle("Nedávné epizody", isOn: Binding(
                get: { settings.current.guardrailsConfig.episodesEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.episodesEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            .padding(.leading, 12)
            Toggle("Úryvky ze souborů", isOn: Binding(
                get: { settings.current.guardrailsConfig.fileExcerptsEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.fileExcerptsEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            .padding(.leading, 12)
            Toggle("Instrukce pro nástroje", isOn: Binding(
                get: { settings.current.guardrailsConfig.skillInstructionsEnabled },
                set: { newValue in
                    var config = settings.current.guardrailsConfig
                    config.skillInstructionsEnabled = newValue
                    Task { await settings.set(\.guardrailsConfig, to: config) }
                }
            ))
            .padding(.leading, 12)

            Divider()
                .padding(.vertical, 4)

            Button(role: .destructive) {
                Task {
                    await personalization.update(assistant: AssistantProfile.defaultAssistant)
                    await settings.update(AppSettings.default)
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Obnovit výchozí")
                }
            }
        } header: {
            Text("Osobnost a bezpečnost")
        } footer: {
            Text("Uprav osobnost asistenta, systémové prompty, bezpečnostní pravidla a kontextové vrstvy.")
        }
    }

    // MARK: - Language & style

    private var languageSection: some View {
        Section {
            Picker("Jazyk", selection: Binding(
                get: { settings.current.language },
                set: { newValue in Task { await settings.set(\.language, to: newValue) } }
            )) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.label).tag(lang)
                }
            }

            Picker("Délka odpovědi", selection: Binding(
                get: { settings.current.answerLength },
                set: { newValue in Task { await settings.set(\.answerLength, to: newValue) } }
            )) {
                ForEach(AnswerLength.allCases) { length in
                    Text(length.label).tag(length)
                }
            }

            TextField("Lokalita (nepovinné)", text: Binding(
                get: { settings.current.locationHint },
                set: { newValue in Task { await settings.set(\.locationHint, to: newValue) } }
            ))
            .textInputAutocapitalization(.words)
        } header: {
            Text("Jazyk a styl")
        } footer: {
            Text("Jazyk je vynucený v systémovém promptu — asistent odpovídá ve zvoleném jazyce i když napíšeš v jiném. Lokalita pomáhá modelu lépe odpovídat na otázky vázané na místo.")
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        Section {
            ForEach(Array(AppSettings.allKnownTools).sorted(), id: \.self) { toolName in
                ToolRow(
                    toolName: toolName,
                    isEnabled: settings.current.enabledTools.contains(toolName),
                    availability: toolAvailability[toolName] ?? .enabled,
                    onToggle: { enabled in
                        Task {
                            // Route through AppContainer.setToolEnabled
                            // so opt-in skills (WebSearch) get registered
                            // / unregistered with SkillManager. A direct
                            // mutation to enabledTools alone left
                            // WebSearch toggled-on-but-not-registered,
                            // and the model correctly reported "I can't
                            // search the web."
                            await container.setToolEnabled(toolName, enabled: enabled)
                            await refreshToolAvailability()
                        }
                    },
                    onGrantPermission: { openAppSettings() }
                )
            }
        } header: {
            Text("Nástroje")
        } footer: {
            Text("Asistent dostane nabídnuté jen povolené nástroje. Matematika jde přes Kalkulačku, kalendářové dotazy přes Kalendář. Zakázané nástroje jsou odmítnuté, i když je model zkusí zavolat.")
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
            NavigationLink("Moje paměť") {
                UserMemoryView()
            }

            Toggle("Zapnout vyhledávací paměť", isOn: Binding(
                get: { settings.current.memoryEnabled },
                set: { newValue in
                    Task { await settings.set(\.memoryEnabled, to: newValue) }
                }
            ))
            Toggle("Automaticky navrhovat fakta z chatů", isOn: Binding(
                get: { settings.current.autoExtractMemory },
                set: { newValue in
                    Task { await settings.set(\.autoExtractMemory, to: newValue) }
                }
            ))
            .disabled(!settings.current.memoryEnabled)

            Button(role: .destructive) {
                Task { await memory.clearAll() }
            } label: {
                Text("Smazat vyhledávací paměť")
            }
        } header: {
            Text("Paměť")
        } footer: {
            Text("Dvě vrstvy: \"Moje paměť\" obsahuje fakta, která sám/sama napíšeš. \"Vyhledávací paměť\" sbírá fakta, která asistent navrhne po každém chatu — neuloží se nic, dokud to nepotvrdíš. Obojí zůstává na tomto zařízení.")
        }
    }

    // MARK: - Generation

    private var generationSection: some View {
        Section {
            // Performance profile — drives the memory safety factor that
            // gates model loads (`RuntimeManager.memorySafetyFactor(for:)`).
            // Kept at the top of the section so users see the global lever
            // before the fine-grained sampler knobs.
            VStack(alignment: .leading, spacing: 4) {
                Picker("Výkonový profil", selection: Binding(
                    get: { settings.current.performanceProfile },
                    set: { newValue in Task { await settings.set(\.performanceProfile, to: newValue) } }
                )) {
                    ForEach(PerformanceProfile.allCases) { profile in
                        Text(profile.label).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.current.performanceProfile.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Streamovat odpovědi", isOn: Binding(
                get: { settings.current.streamingEnabled },
                set: { newValue in Task { await settings.set(\.streamingEnabled, to: newValue) } }
            ))

            HStack {
                Text("Maximum tokenů odpovědi")
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
                Text("Teplota")
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
                Text("Penalizace opakování")
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
            Toggle("Zobrazovat počet tokenů", isOn: Binding(
                get: { settings.current.showTokenUsage },
                set: { newValue in Task { await settings.set(\.showTokenUsage, to: newValue) } }
            ))
        } header: {
            Text("Generování")
        } footer: {
            Text("Vyšší teplota je kreativnější, ale méně předvídatelná. Pro většinu úloh se hodí 0,6–0,8. Penalizace opakování 1,1 a Min-p 0,05 jsou rozumné výchozí hodnoty — menší modely se s nimi tolik nezacyklí ani neprodukují nesmysly.")
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Vzhled") {
            Picker("Motiv", selection: Binding(
                get: { settings.current.theme },
                set: { newValue in Task { await settings.set(\.theme, to: newValue) } }
            )) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            Toggle("Haptická odezva", isOn: Binding(
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

    // MARK: - Hugging Face token

    private var huggingFaceSection: some View {
        Section {
            SecureField("hf_xxx…", text: $hfTokenDraft)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            HStack {
                Button {
                    Task { await validateAndSaveHFToken() }
                } label: {
                    HStack(spacing: 6) {
                        if hfTokenValidating {
                            ProgressView().controlSize(.mini)
                        }
                        Text(hfTokenDraft.isEmpty ? "Vymazat token" : "Ověřit a uložit")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(hfTokenValidating || (hfTokenDraft.isEmpty && !hfTokenStored))

                if let validation = hfTokenLastValidation {
                    switch validation {
                    case .valid:
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Token ověřen")
                    case .invalid:
                        Image(systemName: "xmark.seal.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Token odmítnut")
                    case .networkError:
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Síťová chyba")
                    }
                } else if hfTokenStored {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Token uložen")
                }
            }

            if let msg = hfTokenSaveMessage {
                Text(msg).font(HHTheme.caption).foregroundStyle(.secondary)
            }

            // Live status from the container's foreground re-validation.
            // Takes precedence over the cached `hfTokenLastVerification`
            // row below — if the user backgrounded the app yesterday
            // and HF revoked the token overnight, the cached line still
            // says "ověřeno před 1 dnem" (the *last* successful probe),
            // while this line says "selhalo (orange)" with current
            // information.
            if let live = container.huggingFaceTokenStatus {
                liveStatusRow(live)
            }

            if let verification = hfTokenLastVerification {
                Text("Naposledy ověřeno \(verifiedAgo(verification.at)) — \(verification.username)")
                    .font(HHTheme.caption)
                    .foregroundStyle(.secondary)
            }

            // Post-save retry surface: after a successful validation
            // we scan the catalog for gated models that previously
            // failed (typical reason: "no token configured" or "HF
            // 401"). Each gets a one-tap retry button so the user
            // doesn't have to navigate back to Models and remember
            // which downloads to nudge.
            let retryables = gatedRetryCandidates()
            if !retryables.isEmpty {
                // Per-row retries for fine-grained control.
                ForEach(retryables, id: \.id) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).font(.subheadline)
                            Text("Předchozí pokus selhal kvůli tokenu").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Zkusit znovu") {
                            Task { await modelDownloads.startMLXDownload(model) }
                        }
                        .buttonStyle(HHSecondaryButtonStyle())
                    }
                }
                // Bulk action — appears only when there are 2+
                // candidates so we don't show a meaningless "Stáhnout
                // všechny" for a single row. Confirmation alert
                // quotes the combined size so the user doesn't
                // accidentally kick off 12 GB of downloads on
                // cellular.
                if retryables.count >= 2 {
                    Button {
                        bulkRetryTarget = retryables
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Stáhnout všech \(retryables.count) modelů (\(bulkRetrySize(retryables)))")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(HHSecondaryButtonStyle())
                }
            }
        } header: {
            Text("Hugging Face")
        } footer: {
            Text("Některé MLX modely (Gemma, Llama 3 8B, …) vyžadují přihlášení a přijetí licence. Vytvoř Read-token na huggingface.co/settings/tokens a vlož ho sem — uloží se zašifrovaně do Keychainu a použije při stahování. Token ověříme proti `whoami` před uložením, takže hned uvidíš jestli funguje.")
                .font(HHTheme.caption)
        }
        .onAppear {
            // Lazy-load the stored token so users who never open this
            // section don't pay the Keychain round-trip on every
            // Settings launch. Loaded into the draft so the existing
            // value is visible (SecureField masks the characters).
            if let existing = HFTokenStore.load() {
                hfTokenDraft = existing
                hfTokenStored = true
            } else {
                hfTokenStored = false
            }
            hfTokenSaveMessage = nil
            hfTokenLastValidation = nil
            hfTokenLastVerification = HFTokenStore.lastVerification()
        }
        .confirmationDialog(
            "Spustit stahování?",
            isPresented: Binding(
                get: { bulkRetryTarget != nil },
                set: { if !$0 { bulkRetryTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let models = bulkRetryTarget {
                Button("Spustit \(models.count) stahování", role: .destructive) {
                    Task {
                        for model in models {
                            await modelDownloads.startMLXDownload(model)
                        }
                        bulkRetryTarget = nil
                    }
                }
                Button("Zrušit", role: .cancel) { bulkRetryTarget = nil }
            }
        } message: {
            if let models = bulkRetryTarget {
                Text("Spustí se \(models.count) souběžných stahování v celkové velikosti \(bulkRetrySize(models)). Doporučujeme být na Wi-Fi.")
            }
        }
    }

    /// Human-friendly relative time for the verification timestamp.
    /// Today / včera get explicit labels; older falls back to a
    /// RelativeDateTimeFormatter ("před 3 dny"). Avoids the "verified
    /// at 11:42:01 on 2026-05-15" footgun that looks like debug output
    /// instead of UX.
    private func verifiedAgo(_ date: Date) -> String {
        let rdf = RelativeDateTimeFormatter()
        rdf.locale = Locale(identifier: "cs_CZ")
        rdf.unitsStyle = .full
        return rdf.localizedString(for: date, relativeTo: Date())
    }

    /// Renders the live HF token status as a one-line row with an
    /// icon + label + "Re-ověřit" trailing button. The icon colour
    /// (`green`/`red`/`orange`) and copy are derived from the enum
    /// case so the UI stays in lockstep with what the container
    /// actually knows. Always shown when status is non-nil; if the
    /// last attempt was `.networkError` the row stays orange even
    /// though the underlying token might still be fine — that's
    /// intentional, the user shouldn't trust a stale "green" badge
    /// after a failed retry.
    @ViewBuilder
    private func liveStatusRow(_ live: AppContainer.HFTokenStatus) -> some View {
        HStack(spacing: 6) {
            switch live {
            case .valid(let user, let at):
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Aktivní jako \(user) (ověřeno \(verifiedAgo(at)))")
                    .font(HHTheme.caption)
                    .foregroundStyle(.secondary)
            case .invalid:
                Image(systemName: "xmark.seal.fill")
                    .foregroundStyle(.red)
                Text("Token byl odmítnut — zřejmě vypršel nebo byl odvolán.")
                    .font(HHTheme.caption)
                    .foregroundStyle(.red)
            case .networkError(_, let detail):
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Síťová chyba při ověření: \(detail)")
                    .font(HHTheme.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            // Re-validate button — useful when the user just rotated
            // the token on huggingface.co and wants to confirm without
            // re-pasting. Refreshes the stored verification metadata
            // and the live status in one round trip.
            Button {
                Task { await revalidateExistingToken() }
            } label: {
                Text("Re-ověřit").font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(hfTokenValidating || !hfTokenStored)
        }
    }

    /// Re-runs the whoami probe against the *stored* token (not the
    /// draft). Delegates to `AppContainer.forceRevalidateHFToken()`
    /// so the published live status and the persisted verification
    /// metadata stay in lockstep — using the container path also
    /// means an `.invalid` result actually downgrades the live badge
    /// (the legacy "refresh if stale" path would short-circuit on
    /// cached `.valid` and ignore the new attempt).
    private func revalidateExistingToken() async {
        guard HFTokenStore.hasToken else {
            hfTokenSaveMessage = "Žádný token k ověření — vlož ho výše a klikni Uložit."
            return
        }
        hfTokenValidating = true
        defer { hfTokenValidating = false }

        let result = await container.forceRevalidateHFToken()
        hfTokenLastValidation = result
        hfTokenLastVerification = HFTokenStore.lastVerification()
        switch result {
        case .valid(let username):
            hfTokenSaveMessage = "Token stále funguje (\(username))."
        case .invalid:
            hfTokenSaveMessage = "Token už nefunguje (HTTP 401). Otevři huggingface.co/settings/tokens a vytvoř nový."
        case .networkError(let detail):
            hfTokenSaveMessage = "Síťová chyba: \(detail)"
        case .none:
            hfTokenSaveMessage = "Token zmizel z Keychainu — vlož ho znovu."
        }
    }

    /// Total formatted size for a list of models (skips zero-size
    /// catalog entries — those happen for user-added models that
    /// haven't had a manifest probe yet, so we can't show a real
    /// number). Used by the bulk-retry button label so the user can
    /// decide before tapping.
    private func bulkRetrySize(_ models: [LocalModel]) -> String {
        let total = models.map(\.sizeBytes).filter { $0 > 0 }.reduce(Int64(0), +)
        guard total > 0 else { return "neznámá velikost" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Catalog scan for `requiresAuth` models stuck in `.failed(reason:)`.
    /// Only surfaced once the user has *successfully* validated a token
    /// in this session (`hfTokenLastValidation == .valid`) — otherwise
    /// the row would appear immediately on app launch and confuse a
    /// user who just opened Settings for unrelated reasons. The
    /// substring filter on the reason mirrors `isAuthRelatedFailure`
    /// in ModelsView; a model that failed for disk-space reasons
    /// shouldn't surface here even if it's `requiresAuth`.
    private func gatedRetryCandidates() -> [LocalModel] {
        guard case .valid = hfTokenLastValidation else { return [] }
        return modelCatalog.models.filter { model in
            guard model.requiresAuth else { return false }
            if case .failed(let reason) = model.installState {
                let lc = reason.lowercased()
                return lc.contains("token")
                    || lc.contains("přihlášení")
                    || lc.contains("chráněný")
                    || lc.contains("hugging face")
                    || lc.contains("http 401")
                    || lc.contains("http 403")
            }
            return false
        }
    }

    /// Two-phase save: blank input → clear and short-circuit; non-blank
    /// → validate against `/api/whoami-v2` first, only persist if HF
    /// confirms the token authenticates. Avoids the "I saved this and
    /// thought it worked" footgun where a typo'd token sits in the
    /// Keychain and only fails on the first gated download.
    private func validateAndSaveHFToken() async {
        let trimmed = hfTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            HFTokenStore.clearAll()
            hfTokenStored = false
            hfTokenSaveMessage = "Token vymazán."
            hfTokenLastValidation = nil
            hfTokenLastVerification = nil
            return
        }
        hfTokenValidating = true
        hfTokenSaveMessage = nil
        defer { hfTokenValidating = false }

        let result = await HuggingFaceAPIClient.validateToken(trimmed)
        hfTokenLastValidation = result
        switch result {
        case .valid(let username):
            if HFTokenStore.save(trimmed) {
                hfTokenStored = true
                HFTokenStore.recordVerification(username: username)
                hfTokenLastVerification = HFTokenStore.lastVerification()
                hfTokenSaveMessage = "Přihlášen jako \(username). Token uložen do Keychainu."
            } else {
                hfTokenSaveMessage = "Token je platný, ale uložení do Keychainu selhalo. Zkus znovu."
            }
        case .invalid:
            hfTokenSaveMessage = "Hugging Face token odmítlo (401). Zkontroluj že je platný a má scope `read`."
        case .networkError(let detail):
            hfTokenSaveMessage = "Nelze ověřit (síť): \(detail). Token jsem neuložil — zkus znovu na lepším připojení."
        }
    }

    private var privacySection: some View {
        Section {
            NavigationLink("Soukromí a data") {
                PrivacyView()
            }
            Button(role: .destructive) {
                showRestartOnboardingConfirm = true
            } label: {
                Text("Restartovat onboarding")
            }
        } header: {
            Text("Soukromí")
        } footer: {
            Text("Restart smaže jméno v profilu, styl asistenta a značku, že jsi prošel/prošla onboardingem. Tvoje chaty, paměť a nainstalované modely zůstávají.")
                .font(HHTheme.caption)
        }
        .confirmationDialog(
            "Restartovat onboarding?",
            isPresented: $showRestartOnboardingConfirm,
            titleVisibility: .visible
        ) {
            Button("Restartovat", role: .destructive) {
                Task { await onboarding.reset() }
            }
            Button("Zrušit", role: .cancel) {}
        } message: {
            // Repeated in the dialog body because users frequently
            // miss section footer copy on first read — destructive
            // actions deserve unambiguous wording at the decision
            // point itself.
            Text("Smaže tvůj profil a styl asistenta a znovu spustí uvítací průvodce. Chaty, paměť ani nainstalované modely se nemažou.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Verze", value: Self.appVersion)
            LabeledContent("Runtime", value: runtime.runtime.identifier)
            LabeledContent("Stav runtime", value: runtimeStateLabel)
        } header: {
            Text("O aplikaci")
        }
    }

    /// `CFBundleShortVersionString (CFBundleVersion)` if both are present
    /// (e.g. `"1.0 (12)"`), the marketing version alone if not. Reading
    /// from Info.plist keeps the displayed version in lockstep with the
    /// build settings — no more hardcoded "skeleton" string drifting away
    /// from reality on every release.
    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        if let build = info?["CFBundleVersion"] as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }()

    private var runtimeStateLabel: String {
        switch runtime.state {
        case .idle:            return "Nečinný"
        case .unloading:       return "Uvolňuji"
        case .loading(let id): return "Načítám \(id)"
        case .ready(let id):   return "Připraven — \(id)"
        case .failed:          return "Chyba (viz Diagnostika)"
        }
    }

    // MARK: - Developer

    private var developerSection: some View {
        Section {
            NavigationLink("Diagnostika runtime") {
                DeveloperDiagnosticsView()
            }
            // Value-based link routes through the Route enum so a
            // deep-link append onto `path` from outside ends up in
            // the same destination as a manual tap.
            NavigationLink("Znalostní báze", value: Route.knowledgeBase)
        } header: {
            Text("Pro vývojáře")
        } footer: {
            Text("Aktuální stav runtime, informace o buildu, integrita modelů, log telemetrie a reset — vše dostupné v zařízení bez Xcode.")
        }
    }
}

private struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: UserProfile
    let onSave: (UserProfile) -> Void

    var body: some View {
        Form {
            Section("Jméno") {
                TextField("Tvoje jméno", text: $profile.displayName)
                TextField("Zájmena (např. on/jeho)", text: Binding(
                    get: { profile.pronouns ?? "" },
                    set: { profile.pronouns = $0.isEmpty ? nil : $0 }
                ))
            }
            Section("Práce") {
                TextField("Povolání", text: Binding(
                    get: { profile.occupation ?? "" },
                    set: { profile.occupation = $0.isEmpty ? nil : $0 }
                ))
                TextField("Na čem zrovna děláš", text: Binding(
                    get: { profile.workingContext ?? "" },
                    set: { profile.workingContext = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                    .lineLimit(2...4)
            }
            Section("Zájmy") {
                TextField("Oddělené čárkou", text: Binding(
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
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Uložit") {
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
                // Wrap in a trailing closure so SwiftUI's
                // `@Sendable @MainActor` setter signature doesn't
                // bind directly to our non-Sendable property —
                // the wrapper inherits MainActor isolation from
                // the surrounding View body and stops the warning.
                // (Marking the property `@MainActor @Sendable`
                // tickled a swift-frontend IRGen crash on 6.2.3.)
                Toggle(isOn: Binding(
                    get: { isEnabled },
                    set: { value in onToggle(value) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.humanLabel(for: toolName))
                        Text(statusLine)
                            .font(HHTheme.caption)
                            .foregroundStyle(statusColor)
                    }
                }
            }

            if case .permission = availability {
                Button("Povolit v Nastavení", action: onGrantPermission)
                    .font(HHTheme.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .padding(.leading, 0)
            }
        }
    }

    private var statusLine: String {
        switch availability {
        case .enabled:                 return "Připraveno"
        case .unavailable(let reason): return "Nedostupné — \(reason)"
        case .permission(let prompt):  return "Potřebuje povolení — \(prompt)"
        }
    }

    /// Maps a raw skill name (used as the registry key + on the wire to
    /// the LLM) into a human-friendly label for the toggle row. The
    /// wire format keeps the CamelCase identifiers because changing
    /// them would force every model to relearn the new names; the UI
    /// just renders them prettier.
    static func humanLabel(for skillName: String) -> String {
        switch skillName {
        case "WebSearch":  return "Web Search"
        case "DeviceInfo": return "Device Info"
        case "HomeKit":    return "HomeKit"
        default:           return skillName
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
                Text("HomeHub je záměrně nudný.")
                    .font(HHTheme.title2)
                Text("Žádný účet. Žádný server. Žádná telemetrie. Žádné analytiky. Žádná reklama.")
                    .font(HHTheme.body)
                    .foregroundStyle(HHTheme.textSecondary)

                HHCard {
                    VStack(alignment: .leading, spacing: HHTheme.spaceM) {
                        HHFeatureRow(icon: "externaldrive", title: "Kde jsou tvoje data",
                                     text: "V sandboxu této aplikace na tvém zařízení. Zálohují se spolu se zařízením a nikde jinde.")
                        HHFeatureRow(icon: "network.slash", title: "Síť",
                                     text: "Aplikace sahá na síť jen kvůli stažení modelu, o který sis výslovně řekl/a.")
                        HHFeatureRow(icon: "trash", title: "Mazání",
                                     text: "Vyčištění paměti, smazání chatů nebo odstranění modelů je okamžité a trvalé.")
                    }
                }
            }
            .padding(HHTheme.spaceL)
        }
        .navigationTitle("Soukromí")
        .navigationBarTitleDisplayMode(.inline)
    }
}
