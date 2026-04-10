import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsService

    var body: some View {
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
