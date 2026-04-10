import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsService
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        if hSizeClass == .regular {
            iPadLayout
        } else {
            phoneLayout
        }
    }

    // MARK: - Phone layout (compact width)

    private var phoneLayout: some View {
        TabView(selection: $appState.selectedTab) {
            ChatListView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(MainTab.chat)

            MemoryView()
                .tabItem { Label("Memory", systemImage: "sparkles") }
                .tag(MainTab.memory)

            ModelsView()
                .tabItem { Label("Models", systemImage: "cube.box") }
                .tag(MainTab.models)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .onChange(of: appState.selectedTab) { _, _ in
            HHHaptics.selection(enabled: settings.current.haptics)
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
            case .chat:     ChatListView()
            case .memory:   MemoryView()
            case .models:   ModelsView()
            case .settings: SettingsView()
            }
        }
        .onChange(of: appState.selectedTab) { _, _ in
            HHHaptics.selection(enabled: settings.current.haptics)
        }
    }
}

#Preview {
    let container = AppContainer.preview()
    return MainTabView()
        .environmentObject(container)
        .environmentObject(container.appState)
        .environmentObject(container.settingsService)
        .environmentObject(container.personalizationService)
        .environmentObject(container.modelCatalogService)
        .environmentObject(container.modelDownloadService)
        .environmentObject(container.memoryService)
        .environmentObject(container.runtimeManager)
        .environmentObject(container.conversationService)
        .environmentObject(container.onboardingService)
}
