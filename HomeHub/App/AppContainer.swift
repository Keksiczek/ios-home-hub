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

    /// Number of UIApplication memory-pressure warnings received since launch.
    /// Shown in Developer Diagnostics so you can correlate OOM events with model
    /// unloads without needing Xcode attached.
    @Published private(set) var memoryWarningCount: Int = 0

    /// Human-readable description of the last automatic model unload
    /// (memory pressure or app-background). Nil until the first unload occurs.
    @Published private(set) var lastUnloadNotification: String?

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
    let widgetActionHandler: WidgetActionHandler

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
        let embedding = EmbeddingService()
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
            personalization: personalization,
            embeddingService: embedding
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
        self.widgetActionHandler = WidgetActionHandler()
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

        // Sync current state to the home/lock screen widget.
        WidgetBridge.updateWidget(
            facts: memoryService.facts,
            conversations: conversationService.conversations,
            lastAssistantMessage: nil
        )
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
    /// Also increments `memoryWarningCount` and syncs `RuntimeManager` state
    /// when the runtime auto-unloads the model.
    func handleMemoryPressure() async {
        memoryWarningCount += 1
        if let llama = runtimeManager.runtime as? LlamaCppRuntime {
            await llama.handleMemoryPressure()
            // Sync RuntimeManager if the runtime silently unloaded the model.
            if await llama.currentModel() == nil && runtimeManager.activeModel != nil {
                let name = runtimeManager.activeModel?.displayName ?? "model"
                runtimeManager.clearState()
                let time = DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .medium)
                lastUnloadNotification = "\(time) – '\(name)' unloaded (memory pressure #\(memoryWarningCount))"
            }
        }
    }

    /// Forward scene-phase changes to the runtime.
    func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            if let llama = runtimeManager.runtime as? LlamaCppRuntime {
                await llama.handleBackground()
                // Sync RuntimeManager if the runtime silently unloaded the model.
                if await llama.currentModel() == nil && runtimeManager.activeModel != nil {
                    let name = runtimeManager.activeModel?.displayName ?? "model"
                    runtimeManager.clearState()
                    let time = DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .medium)
                    lastUnloadNotification = "\(time) – '\(name)' unloaded (app backgrounded)"
                }
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
    /// ## Runtime
    /// Always wires `LlamaCppRuntime`. Without `HOMEHUB_REAL_RUNTIME` the
    /// C++ bridge (`LlamaContextHandle`) is a stub that throws a descriptive
    /// error on `load()` — surfaced in `RuntimeManager.state` and visible in
    /// Settings → Developer Diagnostics on device without Xcode attached.
    ///
    /// ## To enable the full real runtime
    /// 1. In Xcode build settings, add `HOMEHUB_REAL_RUNTIME` to
    ///    "Swift Active Compilation Conditions" (both Debug and Release).
    /// 2. Set "Objective-C Bridging Header" to
    ///    `HomeHub/Runtime/Bridge/HomeHub-Bridging-Header.h`.
    /// 3. Link the llama.cpp xcframework under Frameworks, Libraries, and
    ///    Embedded Content.
    /// 4. See `project.yml` for the corresponding XcodeGen configuration.
    static let shared = AppContainer.live()

    static func live() -> AppContainer {
        let runtime: any LocalLLMRuntime = LlamaCppRuntime()

        let store: any Store
        #if HOMEHUB_SWIFTDATA
        store = SwiftDataStore()
        #else
        store = FileStore()
        #endif

        return AppContainer(
            appState: AppState(),
            store: store,
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
