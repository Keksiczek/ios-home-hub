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
    let userMemoryStore: UserMemoryStore
    let personalizationService: PersonalizationService
    let modelCatalogService: ModelCatalogService
    let localModelService: LocalModelService
    let modelDownloadService: ModelDownloadService
    let memoryExtractionService: MemoryExtractionService
    let memoryService: MemoryService
    let promptAssemblyService: PromptAssemblyService
    let promptBudgetReporter: PromptBudgetReporter
    let summarizationService: SummarizationService
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
        let userMemory = UserMemoryStore()
        let personalization = PersonalizationService(
            store: store,
            defaultUser: UserProfile.blank,
            defaultAssistant: AssistantProfile.defaultAssistant
        )
        let catalog = ModelCatalogService()
        let localModels = LocalModelService()
        let downloads = ModelDownloadService(localModels: localModels, catalog: catalog)
        let embedding = EmbeddingService()
        let runtimeManager = RuntimeManager(runtime: runtime)
        // MemoryExtractionService observes runtime load/unload state via the
        // RuntimeManager rather than holding a raw LocalLLMRuntime — keeps
        // every consumer of "is a model loaded?" aligned on the same source
        // of truth and lets the manager intercept the call (telemetry,
        // policy gating) before the runtime sees it.
        let extractor = MemoryExtractionService(runtime: runtimeManager)
        let memory = MemoryService(store: store, settings: settings, extractor: extractor)
        let promptBudgetReporter = PromptBudgetReporter()
        let prompts = PromptAssemblyService(reporter: promptBudgetReporter)
        let summarizer = SummarizationService(runtime: runtimeManager, prompts: prompts)
        let conversations = ConversationService(
            store: store,
            runtime: runtimeManager,
            prompts: prompts,
            memory: memory,
            settings: settings,
            personalization: personalization,
            userMemory: userMemory,
            summarizer: summarizer,
            embeddingService: embedding
        )
        let onboarding = OnboardingService(
            store: store,
            settings: settings,
            personalization: personalization,
            appState: appState
        )

        self.settingsService = settings
        self.userMemoryStore = userMemory
        self.personalizationService = personalization
        self.modelCatalogService = catalog
        self.localModelService = localModels
        self.modelDownloadService = downloads
        self.memoryExtractionService = extractor
        self.memoryService = memory
        self.promptAssemblyService = prompts
        self.promptBudgetReporter = promptBudgetReporter
        self.summarizationService = summarizer
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

        // 1. Merge user-added models into the catalog before reconciling disk state.
        modelCatalogService.loadUserModels()

        // 2. Reconcile every catalog entry against what's actually on disk.
        //    This is the critical fix: catalog states start as .notInstalled on
        //    every cold launch, so without this step the app can never auto-load
        //    a model that was downloaded in a previous session.
        await modelCatalogService.reconcileInstallStates(localModels: localModelService)

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

    /// Promotes a freshly-installed model to `selectedModelID` and loads it
    /// into the runtime when that won't clobber an existing user choice.
    /// Triggered by `ModelDownloadService.onModelInstalled`.
    ///
    /// Behavior change: the chat composer gates `canSend` on
    /// `runtime.activeModel != nil`. Without auto-activation, a fresh
    /// download would leave the runtime empty and the user would think chat
    /// was broken. Rules:
    /// - If no model is currently loaded AND nothing is selected → adopt
    ///   this model as the selection and load it.
    /// - If no model is loaded AND the selected one matches this model (the
    ///   user chose it during onboarding but hadn't downloaded yet) → load it.
    /// - Otherwise (another model already loaded or selected) → no-op.
    func autoActivateAfterInstall(_ model: LocalModel) async {
        guard runtimeManager.activeModel == nil else { return }
        let selected = settingsService.current.selectedModelID
        if selected == nil {
            await settingsService.set(\.selectedModelID, to: model.id)
            await runtimeManager.load(model)
        } else if selected == model.id {
            await runtimeManager.load(model)
        }
    }

    // MARK: - Lifecycle

    /// Forward memory-pressure notification to the runtime via RuntimeManager.
    ///
    /// `RuntimeManager.handleMemoryPressure()` calls through to the runtime's
    /// own implementation (which respects its unload policy) and syncs
    /// `activeModel` / `state` back to idle if an auto-unload occurred.
    func handleMemoryPressure() async {
        memoryWarningCount += 1
        if let unloaded = await runtimeManager.handleMemoryPressure() {
            let time = DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .medium)
            lastUnloadNotification = "\(time) – '\(unloaded.displayName)' unloaded (memory pressure #\(memoryWarningCount))"
        }
    }

    /// Reacts to a `ProcessInfo.thermalStateDidChange` notification. On
    /// `.critical` we unload the model — iOS will throttle the GPU/CPU
    /// and kill hot apps, so holding a multi-GB model in memory at that
    /// point makes termination more likely, not less. `.serious` is
    /// logged for observability but doesn't force an unload yet, since
    /// briefly-hot devices recover without user-visible impact.
    func handleThermalStateChange(_ state: ProcessInfo.ThermalState) async {
        switch state {
        case .critical:
            if let unloaded = await runtimeManager.handleThermalCritical() {
                let time = DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .medium)
                lastUnloadNotification = "\(time) – '\(unloaded.displayName)' unloaded (thermal critical)"
            }
        case .serious, .fair, .nominal:
            break
        @unknown default:
            break
        }
    }

    /// Forward scene-phase changes to the runtime via RuntimeManager.
    func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            if let unloaded = await runtimeManager.handleBackground() {
                let time = DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .medium)
                lastUnloadNotification = "\(time) – '\(unloaded.displayName)' unloaded (app backgrounded)"
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

    /// Production wiring. Uses `FileStore` for persistence and `LlamaCppRuntime`
    /// as the real llama.cpp C++ backend.
    static let shared = AppContainer.live()

    static func live() -> AppContainer {
        let runtime: any LocalLLMRuntime = LlamaCppRuntime()

        let store: any Store
        #if HOMEHUB_SWIFTDATA
        store = SwiftDataStore()
        #else
        store = FileStore()
        #endif

        let container = AppContainer(
            appState: AppState(),
            store: store,
            runtime: runtime
        )
        container.modelDownloadService.onModelInstalled = { [weak container] model in
            await container?.autoActivateAfterInstall(model)
        }
        return container
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
