import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var memory: MemoryService
    @EnvironmentObject private var knowledgeBase: KnowledgeBaseService
    @EnvironmentObject private var personalization: PersonalizationService
    @EnvironmentObject private var settings: SettingsService
    @EnvironmentObject private var conversationService: ConversationService
    @EnvironmentObject private var catalog: ModelCatalogService

    @Environment(\.showSidebarMenu) private var showSidebarMenu

    @State private var memoryHeadroom: RuntimeManager.MemoryHeadroom?
    @State private var isStartingNewChat = false
    @State private var showingMemoryExplainer = false
    @State private var showingPersonaPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HHTheme.spaceXL) {
                    greetingSection
                    hardwareStatusCard
                    quickActionsGrid
                    if isFreshSetup {
                        setupChecklistCard
                    }
                    recentActivities
                    recentDocuments
                    recentFacts
                }
                .padding(.horizontal, HHTheme.spaceL)
                .padding(.vertical, HHTheme.spaceM)
            }
            .background(HHTheme.canvas)
            .sheet(isPresented: $showingMemoryExplainer) {
                memoryExplainerSheet
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingPersonaPicker) {
                PersonaPickerSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            // The Dashboard is the landing tab and the user must always
            // be able to navigate away. The toolbar button alone proved
            // unreliable in some scrolled / split-view states, so the
            // nav bar is hidden entirely and a bulletproof header bar is
            // baked into `greetingSection` instead.
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await refreshMemoryHeadroom()
            }
            .refreshable {
                await refreshMemoryHeadroom()
            }
        }
    }

    // MARK: - Greeting Section

    @ViewBuilder
    private var greetingSection: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            // Always-visible header row: menu trigger (left) + persona
            // pill (right). Lives in the content so the user can never
            // get stuck on the dashboard if the nav-bar toolbar fails
            // to render for any reason (regular-width split, scrolled
            // state, etc.).
            HStack(spacing: HHTheme.spaceM) {
                Button {
                    showSidebarMenu()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(HHTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(HHTheme.surface, in: Circle())
                        .overlay(Circle().stroke(HHTheme.stroke, lineWidth: 1))
                }
                .accessibilityLabel("Otevřít menu")
                .accessibilityHint("Přepnutí mezi sekcemi aplikace")

                Spacer()

                Button {
                    showingPersonaPicker = true
                } label: {
                    personaPill
                }
                .buttonStyle(.plain)
            }
            .accessibilityElement(children: .contain)

            VStack(alignment: .leading, spacing: 4) {
                Text(greetingTimeOfDay)
                    .font(HHTheme.title.weight(.bold))
                    .foregroundStyle(HHTheme.textPrimary)

                Text(activePresetTagline)
                    .font(HHTheme.body)
                    .foregroundStyle(HHTheme.textSecondary)
            }
        }
        .padding(.top, HHTheme.spaceS)
    }

    @ViewBuilder
    private var personaPill: some View {
        let preset = settings.current.activeSystemPromptPreset
        let color = Color(hex: preset.colorHex ?? "007AFF") ?? .blue
        HStack(spacing: 6) {
            Image(systemName: preset.icon ?? "sparkles")
                .font(.caption.weight(.semibold))
            Text(preset.name)
                .font(HHTheme.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aktivní osobnost: \(preset.name)")
        .accessibilityHint("Klepnutím změníš osobnost")
    }
    
    private var greetingTimeOfDay: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let name = personalization.userProfile.displayName.isEmpty ? "" : ", \(personalization.userProfile.displayName)"
        if hour < 12 { return "Dobré ráno\(name)" }
        if hour < 18 { return "Dobré odpoledne\(name)" }
        return "Dobrý večer\(name)"
    }

    private var activePresetTagline: String {
        let preset = settings.current.activeSystemPromptPreset
        if let desc = preset.shortDescription, !desc.isEmpty {
            return desc
        }
        return "Jak ti můžu dnes pomoct?"
    }

    // MARK: - Hardware Status Card
    
    @ViewBuilder
    private var hardwareStatusCard: some View {
        Button {
            appState.selectedTab = .models
        } label: {
            hardwareStatusBody
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stav modelu — \(runtime.activeModel?.displayName ?? "žádný model nenačten"). Paměťová rezerva: \(headroomLabel(for: memoryHeadroom)).")
        .accessibilityHint("Otevře sekci modelů")
    }

    @ViewBuilder
    private var hardwareStatusBody: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            HStack {
                Label("Stav modelu", systemImage: "cpu")
                    .font(HHTheme.headline)
                    .foregroundStyle(HHTheme.textPrimary)
                Spacer()
                hhGlowIndicator(isActive: runtime.activeModel != nil)
            }

            HStack(alignment: .top, spacing: HHTheme.spaceL) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aktivní model")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                    Text(runtime.activeModel?.displayName ?? "Žádný model nenačten")
                        .font(HHTheme.subheadline.weight(.semibold))
                        .foregroundStyle(HHTheme.textPrimary)
                        .lineLimit(1)
                }

                Spacer()

                // Memory tier — its own tap target opens an explainer
                // sheet rather than routing to Models like the rest of
                // the card, so "what does Tight mean?" is one tap away.
                Button {
                    showingMemoryExplainer = true
                } label: {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 3) {
                            Text("Paměťová rezerva")
                                .font(HHTheme.caption)
                                .foregroundStyle(HHTheme.textSecondary)
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(HHTheme.textSecondary.opacity(0.6))
                        }
                        HStack(spacing: 4) {
                            Image(systemName: headroomIcon(for: memoryHeadroom))
                                .font(.caption2)
                            Text(headroomLabel(for: memoryHeadroom))
                                .font(HHTheme.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(headroomColor(for: memoryHeadroom))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paměťová rezerva: \(headroomLabel(for: memoryHeadroom))")
                .accessibilityHint("Otevře vysvětlení")
            }
        }
        .padding(HHTheme.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hhGlassCard()
        .contentShape(Rectangle())
    }

    private func hhGlowIndicator(isActive: Bool) -> some View {
        Circle()
            .fill(isActive ? HHTheme.success : HHTheme.textSecondary)
            .frame(width: 8, height: 8)
            .shadow(color: isActive ? HHTheme.success.opacity(0.8) : .clear, radius: 4)
    }

    // MARK: - Quick Actions

    @ViewBuilder
    private var quickActionsGrid: some View {
        HStack(spacing: HHTheme.spaceM) {
            actionCard(
                title: "Nový chat",
                icon: "plus.message.fill",
                color: HHTheme.accent,
                isBusy: isStartingNewChat
            ) {
                Task { await startNewChat() }
            }

            actionCard(
                title: "Dokumenty",
                icon: "doc.badge.plus",
                color: HHTheme.info
            ) {
                appState.selectedTab = .knowledgeBase
            }

            actionCard(
                title: "Paměť",
                icon: "sparkles",
                color: HHTheme.warning
            ) {
                appState.selectedTab = .memory
            }
        }
    }
    
    private func actionCard(
        title: String,
        icon: String,
        color: Color,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: HHTheme.spaceS) {
                ZStack {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundStyle(color)
                    }
                }
                .frame(height: 32)
                Text(title)
                    .font(HHTheme.caption.weight(.medium))
                    .foregroundStyle(HHTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HHTheme.spaceL)
            .hhCard(cornerRadius: HHTheme.cornerMedium)
            .contentShape(Rectangle())
            .opacity(isBusy ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isBusy ? [.isButton, .updatesFrequently] : .isButton)
    }

    // MARK: - Recent Activities

    @ViewBuilder
    private var recentActivities: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nedávné konverzace")
                    .font(HHTheme.title3)
                    .foregroundStyle(HHTheme.textPrimary)
                Spacer()
                if !conversationService.conversations.isEmpty {
                    Button("Zobrazit vše") {
                        appState.selectedTab = .chat
                    }
                    .font(HHTheme.footnote)
                    .foregroundStyle(HHTheme.accent)
                }
            }
            .padding(.bottom, HHTheme.spaceXS)
            
            // Recent Chats
            let recentChats = Array(conversationService.conversations.prefix(3))
            if !recentChats.isEmpty {
                ForEach(recentChats) { chat in
                    Button {
                        appState.handle(deepLink: .conversation(chat.id))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.title)
                                    .font(HHTheme.subheadline.weight(.medium))
                                    .foregroundStyle(HHTheme.textPrimary)
                                    .lineLimit(1)
                                Text(chat.updatedAt.formatted(.relative(presentation: .named)))
                                    .font(HHTheme.caption)
                                    .foregroundStyle(HHTheme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(HHTheme.textSecondary.opacity(0.5))
                        }
                        .padding(HHTheme.spaceM)
                        .background(HHTheme.surface, in: RoundedRectangle(cornerRadius: HHTheme.cornerMedium))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Zatím žádné konverzace.")
                    .font(HHTheme.footnote)
                    .foregroundStyle(HHTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HHTheme.spaceL)
                    .hhCard()
            }
        }
    }

    // MARK: - Setup checklist (fresh state)

    /// True while the app looks brand-new: no model installed and no
    /// conversations yet. Drives the onboarding checklist so a fresh
    /// install gets concrete next steps instead of three empty cards.
    private var isFreshSetup: Bool {
        !hasInstalledModel && conversationService.conversations.isEmpty
    }

    private var hasInstalledModel: Bool {
        catalog.models.contains { $0.installState.isReady }
    }

    @ViewBuilder
    private var setupChecklistCard: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            Text("Začínáme")
                .font(HHTheme.title3)
                .foregroundStyle(HHTheme.textPrimary)

            checklistRow(
                done: hasInstalledModel,
                title: "Stáhni model",
                subtitle: "Bez modelu nemůže asistent odpovídat.",
                tab: .models
            )
            checklistRow(
                done: !conversationService.conversations.isEmpty,
                title: "Začni první chat",
                subtitle: "Zeptej se na cokoliv — vše běží na zařízení.",
                tab: .chat
            )
            checklistRow(
                done: !knowledgeBase.documents.isEmpty,
                title: "Importuj dokument (nepovinné)",
                subtitle: "Asistent pak umí odpovídat z tvých souborů.",
                tab: .knowledgeBase
            )
        }
        .padding(HHTheme.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hhCard()
    }

    private func checklistRow(done: Bool, title: String, subtitle: String, tab: MainTab) -> some View {
        Button {
            if tab == .chat && !done {
                Task { await startNewChat() }
            } else {
                appState.selectedTab = tab
            }
        } label: {
            HStack(spacing: HHTheme.spaceM) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? HHTheme.success : HHTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(HHTheme.subheadline.weight(.medium))
                        .foregroundStyle(HHTheme.textPrimary)
                        .strikethrough(done, color: HHTheme.textSecondary)
                    Text(subtitle)
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if !done {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(HHTheme.textSecondary.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
    }

    // MARK: - Recent documents

    @ViewBuilder
    private var recentDocuments: some View {
        let docs = Array(
            knowledgeBase.documents
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(3)
        )
        if !docs.isEmpty {
            VStack(alignment: .leading, spacing: HHTheme.spaceM) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Nedávné dokumenty")
                        .font(HHTheme.title3)
                        .foregroundStyle(HHTheme.textPrimary)
                    Spacer()
                    Button("Zobrazit vše") {
                        appState.selectedTab = .knowledgeBase
                    }
                    .font(HHTheme.footnote)
                    .foregroundStyle(HHTheme.accent)
                }
                .padding(.bottom, HHTheme.spaceXS)

                ForEach(docs) { doc in
                    Button {
                        appState.handle(deepLink: .document(doc.id))
                    } label: {
                        HStack {
                            Image(systemName: doc.mimeType.contains("pdf") ? "doc.richtext.fill" : "doc.text.fill")
                                .foregroundStyle(HHTheme.info)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(doc.title)
                                    .font(HHTheme.subheadline.weight(.medium))
                                    .foregroundStyle(HHTheme.textPrimary)
                                    .lineLimit(1)
                                Text("\(doc.chunkCount) úryvků · \(doc.createdAt.formatted(.relative(presentation: .named)))")
                                    .font(HHTheme.caption)
                                    .foregroundStyle(HHTheme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(HHTheme.textSecondary.opacity(0.5))
                        }
                        .padding(HHTheme.spaceM)
                        .background(HHTheme.surface, in: RoundedRectangle(cornerRadius: HHTheme.cornerMedium))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Recent facts

    @ViewBuilder
    private var recentFacts: some View {
        let facts = Array(
            memory.facts
                .filter { !$0.disabled }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(3)
        )
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: HHTheme.spaceM) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Co si pamatuju")
                        .font(HHTheme.title3)
                        .foregroundStyle(HHTheme.textPrimary)
                    Spacer()
                    Button("Zobrazit vše") {
                        appState.selectedTab = .memory
                    }
                    .font(HHTheme.footnote)
                    .foregroundStyle(HHTheme.accent)
                }
                .padding(.bottom, HHTheme.spaceXS)

                ForEach(facts) { fact in
                    Button {
                        appState.handle(deepLink: .memoryFact(fact.id))
                    } label: {
                        HStack(alignment: .top, spacing: HHTheme.spaceM) {
                            Image(systemName: fact.category.symbol)
                                .font(.subheadline)
                                .foregroundStyle(HHTheme.warning)
                                .frame(width: 20)
                            Text(fact.content)
                                .font(HHTheme.subheadline)
                                .foregroundStyle(HHTheme.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(HHTheme.spaceM)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HHTheme.surface, in: RoundedRectangle(cornerRadius: HHTheme.cornerMedium))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Memory explainer

    @ViewBuilder
    private var memoryExplainerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HHTheme.spaceL) {
                    Text("Paměťová rezerva říká, kolik volné RAM má zařízení pro jazykový model. Čím větší rezerva, tím větší a chytřejší model uneseš bez pádů.")
                        .font(HHTheme.body)
                        .foregroundStyle(HHTheme.textSecondary)

                    explainerRow(
                        color: HHTheme.success,
                        icon: "memorychip",
                        title: "Dostatek",
                        text: "Pohodlně zvládneš i větší modely (7–8 B)."
                    )
                    explainerRow(
                        color: HHTheme.warning,
                        icon: "memorychip.fill",
                        title: "Střední",
                        text: "Drž se menších modelů (3–4 B) nebo 4-bit kvantizace."
                    )
                    explainerRow(
                        color: HHTheme.danger,
                        icon: "exclamationmark.triangle.fill",
                        title: "Málo",
                        text: "Velké modely mohou spadnout. Zůstaň u 1–3 B ve 4-bit."
                    )

                    Text("Rezervu ovlivňuje i Výkonový profil v Nastavení — agresivnější profil nechá modelu víc paměti, ale zbude méně pro zbytek systému.")
                        .font(HHTheme.footnote)
                        .foregroundStyle(HHTheme.textSecondary)
                        .padding(.top, HHTheme.spaceS)
                }
                .padding(HHTheme.spaceL)
            }
            .background(HHTheme.canvas)
            .navigationTitle("Paměťová rezerva")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Hotovo") { showingMemoryExplainer = false }
                }
            }
        }
    }

    private func explainerRow(color: Color, icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: HHTheme.spaceM) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HHTheme.subheadline.weight(.semibold))
                    .foregroundStyle(HHTheme.textPrimary)
                Text(text)
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
            }
        }
    }

    // MARK: - Helpers

    private func refreshMemoryHeadroom() async {
        let profileSnapshot = settings.current.performanceProfile
        let result = await Task.detached(priority: .userInitiated) {
            RuntimeManager.currentHeadroom(profile: profileSnapshot)
        }.value
        await MainActor.run {
            memoryHeadroom = result
        }
    }

    @MainActor
    private func startNewChat() async {
        guard !isStartingNewChat else { return }
        isStartingNewChat = true
        HHHaptics.impact(.medium, enabled: settings.current.haptics)
        let conversation = await conversationService.createConversation()
        appState.selectedTab = .chat
        appState.handle(deepLink: .conversation(conversation.id))
        isStartingNewChat = false
    }

    private func headroomLabel(for h: RuntimeManager.MemoryHeadroom?) -> String {
        guard let h else { return "počítá se…" }
        switch h {
        case .high:    return "Dostatek"
        case .medium:  return "Střední"
        case .low:     return "Málo"
        case .unknown: return "Neznámé"
        }
    }
    
    private func headroomIcon(for h: RuntimeManager.MemoryHeadroom?) -> String {
        guard let h else { return "hourglass" }
        switch h {
        case .high:    return "memorychip"
        case .medium:  return "memorychip.fill"
        case .low:     return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    
    private func headroomColor(for h: RuntimeManager.MemoryHeadroom?) -> Color {
        guard let h else { return HHTheme.textSecondary }
        switch h {
        case .high:    return HHTheme.success
        case .medium:  return HHTheme.warning
        case .low:     return HHTheme.danger
        case .unknown: return HHTheme.textSecondary
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppContainer.preview().appState)
        .environmentObject(AppContainer.preview().runtimeManager)
        .environmentObject(AppContainer.preview().memoryService)
        .environmentObject(AppContainer.preview().knowledgeBaseService)
        .environmentObject(AppContainer.preview().personalizationService)
        .environmentObject(AppContainer.preview().settingsService)
        .environmentObject(AppContainer.preview().conversationService)
        .environmentObject(AppContainer.preview().modelCatalogService)
}
