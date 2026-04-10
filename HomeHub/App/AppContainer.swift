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
        let extractor = MemoryExtractionService(runtime: runtime)
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
            // Auto-load the last selected model if it's installed.
            await autoLoadSelectedModel()
        } else {
            appState.phase = .onboarding
        }
    }

    /// Attempts to load the model the user last selected. Called on
    /// launch and after onboarding completes. Silent no-op when no
    /// model is selected or the model file isn't installed yet.
    func autoLoadSelectedModel() async {
        guard let modelID = settingsService.current.selectedModelID,
              let model = modelCatalogService.model(withID: modelID),
              model.installState.isReady,
              runtimeManager.activeModel == nil else { return }
        await runtimeManager.load(model)
    }

    // MARK: - Lifecycle

    /// Forward memory-pressure notification to the runtime.
    func handleMemoryPressure() async {
        if let llama = runtimeManager.runtime as? LlamaCppRuntime {
            await llama.handleMemoryPressure()
        }
    }

    /// Forward scene-phase changes to the runtime.
    func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            if let llama = runtimeManager.runtime as? LlamaCppRuntime {
                await llama.handleBackground()
            }
        case .active:
            // Reload model if it was unloaded while backgrounded.
            if runtimeManager.activeModel == nil {
                await autoLoadSelectedModel()
            }
            // Handle "New chat" intent fired via Siri / Shortcuts.
            if UserDefaults.standard.bool(forKey: "homeHub.pendingNewChat") {
                UserDefaults.standard.removeObject(forKey: "homeHub.pendingNewChat")
                await conversationService.createConversation()
            }
        default:
            break
        }
    }

    // MARK: - Factories

    /// Production wiring. Uses `FileStore` for persistence.
    ///
    /// Runtime selection:
    /// - Default: `MockLocalRuntime` — the app is fully functional with
    ///   simulated inference. Use this until the llama.cpp xcframework
    ///   is integrated.
    /// - To use the real llama.cpp runtime, add `HOMEHUB_REAL_RUNTIME`
    ///   to Swift Active Compilation Conditions in Xcode build settings.
    static func live() -> AppContainer {
        let runtime: any LocalLLMRuntime
        #if HOMEHUB_REAL_RUNTIME
        runtime = LlamaCppRuntime()
        #else
        runtime = MockLocalRuntime()
        #endif
        return AppContainer(
            appState: AppState(),
            store: FileStore(),
            runtime: runtime
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
