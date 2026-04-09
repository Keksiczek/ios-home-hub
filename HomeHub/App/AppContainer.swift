import Foundation
import SwiftUI

/// The single dependency container for the app.
///
/// Created once in `HomeHubApp`. Owns every service, the persistence
/// store, the runtime manager, and the top-level app state. Exposes
/// each dependency as an immutable property so views can reach in
/// through `@EnvironmentObject` injection.
///
/// Two factory methods:
/// - `live()`    — production wiring, uses `FileStore` + the preferred
///                 local runtime (llama.cpp). This is what ships.
/// - `preview()` — in-memory store + `MockLocalRuntime`, used by
///                 SwiftUI previews and tests.
@MainActor
final class AppContainer: ObservableObject {

    let appState: AppState
    let store: any Store

    let settingsService: SettingsService
    let personalizationService: PersonalizationService
    let modelCatalogService: ModelCatalogService
    let localModelService: LocalModelService
    let modelDownloadService: ModelDownloadService
    let memoryExtractionService: MemoryExtractionService
    let memoryService: MemoryService
    let promptAssemblyService: PromptAssemblyService
    let runtimeManager: RuntimeManager
    let conversationService: ConversationService
    let onboardingService: OnboardingService

    private init(
        appState: AppState,
        store: any Store,
        runtime: any LocalLLMRuntime
    ) {
        self.appState = appState
        self.store = store

        let settings = SettingsService(store: store)
        let personalization = PersonalizationService(
            store: store,
            defaultUser: UserProfile.blank,
            defaultAssistant: AssistantProfile.defaultAssistant
        )
        let catalog = ModelCatalogService()
        let localModels = LocalModelService()
        let downloads = ModelDownloadService(localModels: localModels, catalog: catalog)
        let extractor = MemoryExtractionService()
        let memory = MemoryService(store: store, settings: settings, extractor: extractor)
        let prompts = PromptAssemblyService()
        let runtimeManager = RuntimeManager(runtime: runtime)
        let conversations = ConversationService(
            store: store,
            runtime: runtimeManager,
            prompts: prompts,
            memory: memory,
            settings: settings,
            personalization: personalization
        )
        let onboarding = OnboardingService(
            store: store,
            settings: settings,
            personalization: personalization,
            appState: appState
        )

        self.settingsService = settings
        self.personalizationService = personalization
        self.modelCatalogService = catalog
        self.localModelService = localModels
        self.modelDownloadService = downloads
        self.memoryExtractionService = extractor
        self.memoryService = memory
        self.promptAssemblyService = prompts
        self.runtimeManager = runtimeManager
        self.conversationService = conversations
        self.onboardingService = onboarding
    }

    /// Loads persisted state, decides onboarding vs ready, and
    /// publishes the resulting phase. Called once from `RootView`.
    func bootstrap() async {
        await settingsService.load()
        await personalizationService.load()
        await memoryService.load()
        await onboardingService.load()
        await conversationService.load()

        if onboardingService.state.isCompleted {
            appState.phase = .ready
        } else {
            appState.phase = .onboarding
        }
    }

    // MARK: - Factories

    static func live() -> AppContainer {
        AppContainer(
            appState: AppState(),
            store: FileStore(),
            runtime: LlamaCppRuntime()
        )
    }

    static func preview() -> AppContainer {
        let container = AppContainer(
            appState: AppState(),
            store: InMemoryStore.populated(),
            runtime: MockLocalRuntime()
        )
        container.appState.phase = .ready
        return container
    }
}
