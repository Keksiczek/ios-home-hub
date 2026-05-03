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

    /// Structured snapshot of the most recent automatic unload, surfaced
    /// to the chat UI as a non-blocking banner ("Model unloaded — Reload?").
    /// `nil` once the user dismisses the banner OR once the model is
    /// successfully reloaded — both reset paths run through
    /// `acknowledgeUnloadNotice()`.
    @Published private(set) var pendingUnloadNotice: UnloadNotice?

    /// Single unload event ready to be rendered as a recovery banner. We
    /// keep the `modelID` alongside the display name so the Reload button
    /// can route to the same model the runtime had loaded — the user may
    /// have switched their selection between unload and dismiss.
    struct UnloadNotice: Equatable {
        let modelID: String
        let displayName: String
        let reason: Reason
        let occurredAt: Date

        enum Reason: String, Equatable {
            case memoryPressure
            case thermalCritical
            case appBackground

            /// User-facing one-liner. Localised informally because this
            /// shows up in the chat surface, not Settings.
            var label: String {
                switch self {
                case .memoryPressure:  return "Low memory — model unloaded."
                case .thermalCritical: return "Device too hot — model unloaded."
                case .appBackground:   return "App was backgrounded — model unloaded."
                }
            }
        }
    }

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

        // WebSearch is the one tool that's NOT registered by default in
        // `SkillManager.init` — it needs explicit user consent, and the
        // privacy rail in `PromptAssemblyService` flips based on whether
        // it's actually registered. Now that settings have loaded we know
        // whether the user has it enabled, so register it here once.
        await registerWebSearchIfEnabled()

        // 1. Merge user-added models into the catalog before reconciling disk state.
        modelCatalogService.loadUserModels()

        // 2. Reconcile every catalog entry against what's actually on disk.
        //    This is the critical fix: catalog states start as .notInstalled on
        //    every cold launch, so without this step the app can never auto-load
        //    a model that was downloaded in a previous session.
        await modelCatalogService.reconcileInstallStates(localModels: localModelService)

        // 3. Drop resume data that's either too old to be useful or
        //    attached to models that no longer exist in the catalog.
        //    Has to run AFTER user-models load + disk reconciliation so
        //    we don't accidentally treat a still-known model as gone.
        modelDownloadService.pruneStaleResumeData()

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

    /// Registers `WebSearchSkill(engine: DuckDuckGoLiteEngine())` with the
    /// shared `SkillManager` iff the user has `WebSearch` in
    /// `AppSettings.enabledTools`. Idempotent — re-registering with the
    /// same name just replaces the engine.
    ///
    /// Called from `bootstrap()` after settings load, and from
    /// `setWebSearchEnabled(_:)` whenever the user toggles the row in
    /// Settings. The toggle path keeps the registry aligned with the
    /// allow-list without forcing a relaunch.
    private func registerWebSearchIfEnabled() async {
        let enabled = settingsService.current.enabledTools
            .map { $0.lowercased() }
            .contains("websearch")
        if enabled {
            await SkillManager.shared.register(WebSearchSkill(engine: DuckDuckGoLiteEngine()))
        }
    }

    /// Convenience: toggle the WebSearch tool from Settings UI without
    /// reaching into both `SettingsService` and `SkillManager` directly.
    /// Persists the allow-list change AND registers/unregisters the skill
    /// so the next prompt assembly reflects the user's choice.
    func setWebSearchEnabled(_ enabled: Bool) async {
        var tools = settingsService.current.enabledTools
        if enabled {
            tools.insert("WebSearch")
            await settingsService.set(\.enabledTools, to: tools)
            await SkillManager.shared.register(WebSearchSkill(engine: DuckDuckGoLiteEngine()))
        } else {
            tools.remove("WebSearch")
            await settingsService.set(\.enabledTools, to: tools)
            // Note: SkillManager has no `unregister`. Leaving the skill
            // registered is harmless — the allow-list (`enabledTools`) is
            // the single source of truth at call time, so a registered-but-
            // disabled skill is filtered out of the L4 instructions and
            // refused at dispatch time.
        }
    }

    /// Dismisses the in-chat unload banner without reloading. Used by
    /// the banner's "x" button when the user wants to acknowledge the
    /// event but defer recovery (e.g. they're done with the chat for now).
    func acknowledgeUnloadNotice() {
        pendingUnloadNotice = nil
    }

    /// Re-loads the model referenced by the pending banner. Looks the
    /// model up in the catalog by ID rather than trusting a captured
    /// `LocalModel`, so download-state changes between unload and reload
    /// (e.g. the user re-imported it under a new ID) don't blow up.
    func reloadFromUnloadNotice() async {
        guard let notice = pendingUnloadNotice else { return }
        defer { pendingUnloadNotice = nil }
        if let model = modelCatalogService.model(withID: notice.modelID),
           model.installState.isReady {
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
            pendingUnloadNotice = UnloadNotice(
                modelID: unloaded.id,
                displayName: unloaded.displayName,
                reason: .memoryPressure,
                occurredAt: .now
            )
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
                pendingUnloadNotice = UnloadNotice(
                    modelID: unloaded.id,
                    displayName: unloaded.displayName,
                    reason: .thermalCritical,
                    occurredAt: .now
                )
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
                // Note: we DON'T set `pendingUnloadNotice` for the
                // app-background case — the next foreground transition
                // (`.active` below) auto-reloads the model, so the user
                // never sees the chat in a broken state and a banner
                // would only flash on screen for a fraction of a second.
            }
        case .active:
            // Reload model if it was unloaded while backgrounded.
            if runtimeManager.activeModel == nil {
                await autoLoadSelectedModel()
            }
            // If the auto-reload (or the user's earlier action) restored
            // the model the banner is referring to, drop the banner — its
            // recovery suggestion is no longer useful.
            if let notice = pendingUnloadNotice,
               runtimeManager.activeModel?.id == notice.modelID {
                pendingUnloadNotice = nil
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

    /// Production wiring. Uses `FileStore` for persistence and `MLXRuntime`
    /// as the primary backend. `LlamaCppRuntime` is only constructed when the
    /// build opts in to llama.cpp via `HOMEHUB_LLAMA_RUNTIME` (default: off).
    static let shared = AppContainer.live()

    static func live() -> AppContainer {
        let mlx: MLXRuntime
        if ProcessInfo.processInfo.arguments.contains("--use-fake-mlx-loader") {
            let fake = FakeMLXLoader()
            if let behavior = ProcessInfo.processInfo.environment["MLX_LOAD_BEHAVIOR"] {
                switch behavior {
                case "failure":
                    fake.behavior = .failure("Simulated loading failure")
                case "slow":
                    fake.behavior = .slowProgress(steps: 10, delay: 0.1)
                default:
                    fake.behavior = .success
                }
            }
            mlx = MLXRuntime(loader: fake)
        } else {
            mlx = MLXRuntime()
        }

        #if HOMEHUB_LLAMA_RUNTIME
        let llama = LlamaCppRuntime()
        let runtime: any LocalLLMRuntime = RoutingRuntime(llamaCpp: llama, mlx: mlx)
        #else
        let runtime: any LocalLLMRuntime = RoutingRuntime(mlx: mlx)
        #endif

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
