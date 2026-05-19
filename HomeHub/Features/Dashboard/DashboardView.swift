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
            .navigationTitle("Home")
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
                
                Text("Ready to help you today.")
                    .font(HHTheme.body)
                    .foregroundStyle(HHTheme.textSecondary)
            }
            Spacer()
        }
        .padding(.top, HHTheme.spaceS)
    }
    
    private var greetingTimeOfDay: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let name = personalization.userProfile.displayName.isEmpty ? "" : " \(personalization.userProfile.displayName)"
        if hour < 12 { return "Good morning\(name)" }
        if hour < 18 { return "Good afternoon\(name)" }
        return "Good evening\(name)"
    }

    // MARK: - Hardware Status Card
    
    @ViewBuilder
    private var hardwareStatusCard: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            HStack {
                Label("Hardware Status", systemImage: "cpu")
                    .font(HHTheme.headline)
                    .foregroundStyle(HHTheme.textPrimary)
                Spacer()
                if runtime.activeModel != nil {
                    hhGlowIndicator(isActive: true)
                }
            }
            
            HStack(alignment: .top, spacing: HHTheme.spaceL) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                    Text(runtime.activeModel?.displayName ?? "No model loaded")
                        .font(HHTheme.subheadline.weight(.semibold))
                        .foregroundStyle(HHTheme.textPrimary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Memory Tier")
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
        .hhGlassCard()
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
                title: "New Chat",
                icon: "plus.message.fill",
                color: HHTheme.accent
            ) {
                // Switching to chat tab creates a fresh state natively
                // if we just select the tab and clear existing state.
                appState.selectedTab = .chat
            }
            
            actionCard(
                title: "Import Doc",
                icon: "doc.badge.plus",
                color: HHTheme.info
            ) {
                appState.selectedTab = .knowledgeBase
            }
            
            actionCard(
                title: "Memory",
                icon: "sparkles",
                color: HHTheme.warning
            ) {
                appState.selectedTab = .memory
            }
        }
    }
    
    private func actionCard(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: HHTheme.spaceS) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(height: 32)
                Text(title)
                    .font(HHTheme.caption.weight(.medium))
                    .foregroundStyle(HHTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HHTheme.spaceL)
            .hhCard(cornerRadius: HHTheme.cornerMedium)
            // Hover/press effect simulation using theme animation
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent Activities

    @ViewBuilder
    private var recentActivities: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            Text("Recent Activity")
                .font(HHTheme.title3)
                .foregroundStyle(HHTheme.textPrimary)
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
                Text("No recent conversations.")
                    .font(HHTheme.footnote)
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
    
    private func headroomLabel(for h: RuntimeManager.MemoryHeadroom?) -> String {
        guard let h else { return "Computing..." }
        switch h {
        case .high:    return "Generous"
        case .medium:  return "Moderate"
        case .low:     return "Tight"
        case .unknown: return "Unknown"
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
