import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var settings: SettingsService
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showingSidebar = false

    var body: some View {
        if hSizeClass == .regular {
            iPadLayout
        } else {
            phoneLayout
        }
    }

    // MARK: - Phone layout (compact width)
    //
    // v2: no tab bar. One destination fills the screen; switching
    // happens through a sheet-style sidebar menu triggered by the
    // hamburger button that each destination hosts in its nav bar.
    //
    // **Navigation contract** — every destination listed below MUST
    // host its own `NavigationStack` at the root of its body. This
    // layout deliberately does not provide one (path-driven destinations
    // like ChatListView need their own `NavigationStack(path:)`). If
    // you add a new tab, wrap its body in `NavigationStack { … }` and
    // attach `.toolbar { ToolbarItem(placement: .topBarLeading) {
    // SidebarMenuButton() } }` so the user can navigate away — KB and
    // Dashboard both shipped broken before this comment existed.

    private var phoneLayout: some View {
        Group {
            switch appState.selectedTab {
            case .dashboard:     DashboardView()
            case .chat:          ChatListView()
            case .knowledgeBase: KnowledgeBaseView()
            case .memory:        MemoryView()
            case .models:        ModelsView()
            case .settings:      SettingsView()
            }
        }
        .overlay(alignment: .bottom) {
            loadingOverlay
        }
        // EnvironmentKey is `@Sendable () -> Void`. Hop to MainActor
        // before mutating the @State so the closure stays Sendable
        // and Swift 6 strict concurrency is happy.
        .environment(\.showSidebarMenu, {
            Task { @MainActor in showingSidebar = true }
        })
        .sheet(isPresented: $showingSidebar) {
            SidebarMenuView { tab in
                appState.selectedTab = tab
                HHHaptics.selection(enabled: settings.current.haptics)
                showingSidebar = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - iPad layout (regular width)

    private var iPadLayout: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(
                MainTab.allCases,
                selection: Binding<MainTab?>(
                    get: { appState.selectedTab },
                    set: { appState.selectedTab = $0 ?? .chat }
                )
            ) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .tag(tab)
            }
            .navigationTitle("HomeHub")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
            .listStyle(.sidebar)
        } detail: {
            // Each tab is a full NavigationStack so deep-links work correctly.
            switch appState.selectedTab {
            case .dashboard:     DashboardView()
            case .chat:          ChatListView()
            case .knowledgeBase: KnowledgeBaseView()
            case .memory:        MemoryView()
            case .models:        ModelsView()
            case .settings:      SettingsView()
            }
        }
        .overlay(alignment: .bottom) {
            loadingOverlay
        }
        .onChange(of: appState.selectedTab) { _, _ in
            HHHaptics.selection(enabled: settings.current.haptics)
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if case .loading(let modelID) = runtime.state {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading \(modelID.split(separator: "/").last ?? "model")…")
                    .font(HHTheme.caption.weight(.medium))
                    .foregroundStyle(HHTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(HHTheme.surface)
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            )
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: modelID)
        }
    }
}

#Preview {
    let container = AppContainer.preview()
    return MainTabView()
        .environmentObject(container)
        .environmentObject(container.appState)
        .environmentObject(container.settingsService)
        .environmentObject(container.userMemoryStore)
        .environmentObject(container.personalizationService)
        .environmentObject(container.modelCatalogService)
        .environmentObject(container.modelDownloadService)
        .environmentObject(container.memoryService)
        .environmentObject(container.runtimeManager)
        .environmentObject(container.conversationService)
        .environmentObject(container.onboardingService)
        .environmentObject(container.promptBudgetReporter)
}
