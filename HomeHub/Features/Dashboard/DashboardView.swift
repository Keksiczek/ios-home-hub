import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var memory: MemoryService
    @EnvironmentObject private var knowledgeBase: KnowledgeBaseService
    @EnvironmentObject private var personalization: PersonalizationService
    @EnvironmentObject private var settings: SettingsService
    @EnvironmentObject private var conversationService: ConversationService

    @State private var memoryHeadroom: RuntimeManager.MemoryHeadroom?
    @State private var isStartingNewChat = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HHTheme.spaceXL) {
                    greetingSection
                    hardwareStatusCard
                    quickActionsGrid
                    recentActivities
                }
                .padding(.horizontal, HHTheme.spaceL)
                .padding(.vertical, HHTheme.spaceM)
            }
            .background(HHTheme.canvas)
            .navigationTitle("Domů")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarMenuButton()
                }
            }
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
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(greetingTimeOfDay)
                    .font(HHTheme.title.weight(.bold))
                    .foregroundStyle(HHTheme.textPrimary)

                Text(activePresetTagline)
                    .font(HHTheme.body)
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Spacer()
        }
        .padding(.top, HHTheme.spaceS)
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

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Paměťová rezerva")
                            .font(HHTheme.caption)
                            .foregroundStyle(HHTheme.textSecondary)
                        HStack(spacing: 4) {
                            Image(systemName: headroomIcon(for: memoryHeadroom))
                                .font(.caption2)
                            Text(headroomLabel(for: memoryHeadroom))
                                .font(HHTheme.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(headroomColor(for: memoryHeadroom))
                    }
                }
            }
            .padding(HHTheme.spaceL)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hhGlassCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
}
