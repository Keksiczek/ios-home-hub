import SwiftUI

@main
struct HomeHubApp: App {
    @StateObject private var container = AppContainer.live()
    @Environment(\.scenePhase) private var scenePhase

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
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )) { _ in
                    Task { await container.handleMemoryPressure() }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task { await container.handleScenePhaseChange(newPhase) }
                }
        }
    }
}
