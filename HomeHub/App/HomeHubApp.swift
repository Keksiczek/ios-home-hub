import SwiftUI

@main
struct HomeHubApp: App {
    @StateObject private var container = AppContainer.live()

    var body: some Scene {
        WindowGroup {
            RootView()
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
                .tint(HHTheme.accent)
                .preferredColorScheme(nil)
        }
    }
}
