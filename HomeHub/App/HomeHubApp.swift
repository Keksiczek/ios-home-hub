import SwiftUI

@main
struct HomeHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container = AppContainer.shared
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
                .environmentObject(container.widgetActionHandler)
                .environmentObject(container.promptBudgetReporter)
                .tint(HHTheme.accent)
                .preferredColorScheme(container.settingsService.current.theme.colorScheme)
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )) { _ in
                    Task { await container.handleMemoryPressure() }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: ProcessInfo.thermalStateDidChangeNotification
                )) { _ in
                    // Snapshot on the notification thread; forward to the
                    // container on the main actor. ProcessInfo reads are
                    // thread-safe, so this doesn't need isolation.
                    let state = ProcessInfo.processInfo.thermalState
                    Task { await container.handleThermalStateChange(state) }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task { await container.handleScenePhaseChange(newPhase) }
                }
        }
    }
}
