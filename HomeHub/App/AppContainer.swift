import Foundation
import SwiftUI
import Combine
import os

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
            /// shows up in the chat surface, not Settings. The wording
            /// names the cause explicitly so the user can correlate the
            /// banner with what they just did (open a heavy app, leave
            /// the phone in the sun, etc.) rather than blaming the chat.
            var label: String {
                switch self {
                case .memoryPressure:  return "Model byl uvolněn kvůli nízké paměti."
                case .thermalCritical: return "Model byl uvolněn kvůli přehřátí zařízení."
                case .appBackground:   return "Model byl uvolněn po přechodu na pozadí."
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
    let knowledgeBaseService: KnowledgeBaseService
    /// Shared NLContextualEmbedding wrapper used by Memory,
    /// Conversation and KnowledgeBase services. Held on the
    /// container so the memory-pressure path can call `unload()`
    /// without reaching through one of the consumers.
    let embeddingService: EmbeddingService
    /// Spotlight indexer. Background-isolated `actor`; views never
    /// touch it directly — services call into it from their save
    /// hooks so the index stays in sync without UI involvement.
    let searchIndexingService: SearchIndexingService

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
        // Share a single EmbeddingService across MemoryService and
        // ConversationService so they share the model load AND the LRU
        // cache. Two separate instances meant two model loads and stale
        // cache misses on every turn.
        let memory = MemoryService(
            store: store,
            settings: settings,
            extractor: extractor,
            embeddings: embedding
        )
        let promptBudgetReporter = PromptBudgetReporter()
        let prompts = PromptAssemblyService(reporter: promptBudgetReporter)
        let summarizer = SummarizationService(runtime: runtimeManager, prompts: prompts)
        // Forward-declared placeholders so the container instance can
        // be captured by the callbacks below before `self` is fully
        // formed. `Unmanaged` would be the most efficient route, but
        // a weak holder via a small reference type keeps the
        // ownership story obvious and avoids ARC subtleties for a
        // path that fires at most once per generation.
        final class WeakSelf { weak var value: AppContainer? }
        let weakHolder = WeakSelf()

        let conversations = ConversationService(
            store: store,
            runtime: runtimeManager,
            prompts: prompts,
            memory: memory,
            settings: settings,
            personalization: personalization,
            userMemory: userMemory,
            summarizer: summarizer,
            embeddingService: embedding,
            promptBudgetReporter: promptBudgetReporter,
            recentBackgroundTimestamp: { [weak weakHolder] in
                weakHolder?.value?.lastBackgroundedAt
            },
            onBackgroundCompletion: { [weak weakHolder] in
                weakHolder?.value?.recordBackgroundGenerationCompletion()
            }
        )
        let onboarding = OnboardingService(
            store: store,
            settings: settings,
            personalization: personalization,
            appState: appState,
            // Probe both MLX cache repos AND GGUF model IDs so an
            // iCloud / Quick Start restore that includes either
            // format surfaces a skip option. Catalog lookup happens
            // on-demand in the welcome view; the probe just returns
            // the raw identifiers.
            installedModelProbe: { [weak localModels, weak catalog] in
                guard let localModels, let catalog else { return [] }
                let mlxRepos = await localModels.enumerateMLXCacheRepos()
                let ggufIDs = await localModels.installedModelIDs()
                // Translate MLX repo → catalog model ID where possible
                // so callers can hand the result straight to
                // `acceptRestoredModel(_:)`. Falls back to repo string
                // when no curated entry matches (user-added models).
                let mlxModelIDs: [String] = await MainActor.run {
                    mlxRepos.map { repo in
                        catalog.models.first(where: { $0.repoId == repo })?.id ?? repo
                    }
                }
                let combined = Array(Set(mlxModelIDs).union(ggufIDs))
                return combined.sorted()
            }
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
        // Knowledge Base reuses the shared EmbeddingService so we
        // don't double-load the NLContextualEmbedding assets — same
        // reasoning that drives the single-instance pattern in
        // MemoryService / ConversationService above.
        self.knowledgeBaseService = KnowledgeBaseService(embedding: embedding)
        self.embeddingService = embedding
        self.searchIndexingService = SearchIndexingService()
        // Spotlight subscriptions: re-fire on every published
        // change to memory facts / conversations / KB documents.
        // The diff against the previous snapshot is computed
        // inside the closure so we only push updates / deletes
        // for items that actually changed. `dropFirst(1)` skips
        // the synchronous initial value (bootstrap covers that)
        // so we don't double-index at launch.
        wireSpotlightSubscriptions(
            memory: memory,
            conversations: conversations,
            knowledgeBase: knowledgeBaseService
        )

        // Plumb the GGUF metadata cache into the runtime so per-load logs
        // can name the template source and effective context. Weak capture
        // because RuntimeManager outlives single bootstraps and we don't
        // want a retain loop through the container.
        runtimeManager.ggufMetadataProvider = { [weak catalog] modelID in
            catalog?.metadata(for: modelID)
        }

        // Publish `self` to the weak holder consumed by the
        // ConversationService callbacks. Done at the very end of
        // init so every stored property is in place — accessing
        // `self` earlier would trip Swift's "used before init"
        // diagnostic since the storage isn't complete yet.
        weakHolder.value = self
    }

    // MARK: - Spotlight subscriptions

    private var spotlightCancellables: Set<AnyCancellable> = []
    private var lastIndexedFactIDs: Set<UUID> = []
    private var lastIndexedConversationIDs: Set<UUID> = []
    private var lastIndexedDocumentIDs: Set<UUID> = []

    private func wireSpotlightSubscriptions(
        memory: MemoryService,
        conversations: ConversationService,
        knowledgeBase: KnowledgeBaseService
    ) {
        // MemoryFact diff. Adds/updates pushed wholesale (cheap;
        // dozens of facts max), removed IDs (= last-known minus
        // current) pushed as deletes.
        memory.$facts
            .dropFirst()
            .sink { [weak self] facts in
                guard let self else { return }
                let currentIDs = Set(facts.map(\.id))
                let removed = self.lastIndexedFactIDs.subtracting(currentIDs)
                self.lastIndexedFactIDs = currentIDs
                let snapshot = facts
                Task { [weak self] in
                    guard let self else { return }
                    if !removed.isEmpty {
                        await self.searchIndexingService.remove(memoryFactIDs: Array(removed))
                    }
                    await self.searchIndexingService.index(memoryFacts: snapshot)
                }
            }
            .store(in: &spotlightCancellables)

        // Conversation diff (titles + timestamps; message bodies
        // are intentionally NOT indexed — see SearchIndexingService).
        conversations.$conversations
            .dropFirst()
            .sink { [weak self] convs in
                guard let self else { return }
                let currentIDs = Set(convs.map(\.id))
                let removed = self.lastIndexedConversationIDs.subtracting(currentIDs)
                self.lastIndexedConversationIDs = currentIDs
                let snapshot = convs
                Task { [weak self] in
                    guard let self else { return }
                    if !removed.isEmpty {
                        await self.searchIndexingService.remove(conversationIDs: Array(removed))
                    }
                    await self.searchIndexingService.index(conversations: snapshot)
                }
            }
            .store(in: &spotlightCancellables)

        // KB document diff. Same pattern — removed IDs flushed,
        // current array reindexed (idempotent on uniqueIdentifier).
        knowledgeBase.$documents
            .dropFirst()
            .sink { [weak self] docs in
                guard let self else { return }
                let currentIDs = Set(docs.map(\.id))
                let removed = self.lastIndexedDocumentIDs.subtracting(currentIDs)
                self.lastIndexedDocumentIDs = currentIDs
                let snapshot = docs
                Task { [weak self] in
                    guard let self else { return }
                    if !removed.isEmpty {
                        await self.searchIndexingService.remove(documentIDs: Array(removed))
                    }
                    await self.searchIndexingService.index(documents: snapshot)
                }
            }
            .store(in: &spotlightCancellables)
    }

    /// Loads persisted state, decides onboarding vs ready, and
    /// publishes the resulting phase. Called once from `RootView`.
    ///
    /// ## Parallelisation
    /// The five service `.load()` calls each hit a separate JSON
    /// file and don't observe each other's state — running them
    /// sequentially with `await` was making cold start serial-IO
    /// bound. `async let` fires them concurrently; the trailing
    /// `_ = await (...)` waits for the slowest. Net cold-start
    /// win on a fresh device with cold disk caches: roughly the
    /// difference between sum-of-IO and max-of-IO.
    ///
    /// `registerWebSearchIfEnabled()` and the catalog reconcile
    /// step both depend on settings being loaded, so they stay
    /// after the await barrier.
    func bootstrap() async {
        async let settingsLoad: Void = settingsService.load()
        async let personLoad:  Void = personalizationService.load()
        async let memoryLoad:  Void = memoryService.load()
        async let onboardLoad: Void = onboardingService.load()
        async let convLoad:    Void = conversationService.load()
        _ = await (settingsLoad, personLoad, memoryLoad, onboardLoad, convLoad)

        // Sync the chosen performance profile into the runtime once
        // settings have actually loaded from disk, then keep it in sync
        // for the rest of the session. Live edits in Settings publish
        // through `settings.$current` and the sink pushes a new factor
        // into the runtime; the next `load()` picks it up automatically.
        runtimeManager.performanceProfile = settingsService.current.performanceProfile
        settingsService.$current
            .map(\.performanceProfile)
            .removeDuplicates()
            .sink { [weak runtimeManager] profile in
                runtimeManager?.performanceProfile = profile
            }
            .store(in: &spotlightCancellables)   // re-use the existing cancellables bag

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

        // 2b. Project still-alive background transports onto the catalog
        //     installState. After an OS-driven relaunch the URLSession task
        //     can survive in nsurlsessiond, but the catalog reconcile above
        //     just set the model to `.notInstalled` because no file is on
        //     disk yet. Without this step the UI would offer a "Download"
        //     button that immediately bails (DownloadManager.isActive
        //     short-circuits start()), and the user would be stuck looking
        //     at a stale state until the first delegate progress callback
        //     fires — which can take seconds on a slow link. Seeding
        //     `.downloading(progress: 0)` here lets ModelBrowserViewModel
        //     render the `.reconnecting` row immediately.
        let liveTransports = DownloadManager.shared.activeModelIDs
        if !liveTransports.isEmpty {
            for id in liveTransports {
                if let model = modelCatalogService.model(withID: id),
                   case .installed = model.installState {
                    // File already on disk; the transport is a stale survivor.
                    // Leave the catalog state at `.installed` and let the
                    // download manager clean itself up via reconnect orphan
                    // recovery on the next event.
                    continue
                }
                modelCatalogService.setInstallState(.downloading(progress: 0), for: id)
            }
        }

        // 3. Drop resume data that's either too old to be useful or
        //    attached to models that no longer exist in the catalog.
        //    Has to run AFTER user-models load + disk reconciliation so
        //    we don't accidentally treat a still-known model as gone.
        modelDownloadService.pruneStaleResumeData()

        // 3b. Sweep MLX cache directories — both orphans (no catalog
        //     entry) and broken installs (catalog says installed but the
        //     cache is missing weights / tokenizer / config for at least
        //     7 days). Typical sources:
        //       * orphan: user deleted a custom model while its multi-GB
        //         download was running; curated entry renamed across an
        //         app version bump.
        //       * broken: download interrupted by force-quit / jetsam;
        //         partial restore from iCloud; bit-rot on a shard.
        //     The broken-cache pass also flips the catalog entry back to
        //     `.notInstalled` so the user gets a Download button instead
        //     of a deceptive "Installed" badge on a half-broken model.
        //     Detached so a slow disk walk on a large cache doesn't
        //     stall onboarding; cleanup is purely a hygiene pass and
        //     the result lands when it lands.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.modelDownloadService.runMLXCacheHygiene()
        }

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

        // Drain any ingest jobs queued by the Share Extension since
        // last launch, then publish the latest documents/jobs to the
        // debug surface. Doesn't block onboarding — it's intentionally
        // run after we've flipped `appState.phase` to keep first
        // launch responsive even if the queue is large.
        await knowledgeBaseService.bootstrap()

        // Spotlight bootstrap. One-shot per install: full reindex
        // from the loaded state. Subsequent runs go through
        // incremental hooks (`indexAfterChange` calls on the
        // services). Detached so this never blocks the main actor
        // even on a freshly-imported corpus.
        let docs = knowledgeBaseService.documents
        let convs = conversationService.conversations
        let facts = memoryService.facts
        // Seed the diff sets so the first incremental publish
        // doesn't see "everything is new". Without this the very
        // first refresh after bootstrap would push a redundant
        // full reindex (idempotent but wasteful) and an empty
        // delete batch.
        lastIndexedDocumentIDs = Set(docs.map(\.id))
        lastIndexedConversationIDs = Set(convs.map(\.id))
        lastIndexedFactIDs = Set(facts.map(\.id))
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.searchIndexingService.bootstrap(
                documents: docs,
                conversations: convs,
                memoryFacts: facts
            )
        }
    }

    /// Attempts to load the model the user last selected. Called on
    /// launch and after onboarding completes. Silent no-op when no
    /// model is selected or the model file isn't installed yet.
    ///
    /// ## Crash-loop guard
    /// A flag is written to UserDefaults immediately before
    /// `runtime.load()` and cleared on success. If the flag is still
    /// set when we next reach this method (i.e. the app crashed
    /// mid-load on the previous launch — typically OOM during Metal
    /// pipeline compile) we skip the auto-load and surface the event
    /// via `lastAutoLoadCrash`, leaving the user in control. The user
    /// can still tap Load manually from the Models screen, which goes
    /// through `RuntimeManager.load(_:)` directly — the guard only
    /// inhibits the silent boot-time path.
    func autoLoadSelectedModel() async {
        guard let modelID = settingsService.current.selectedModelID,
              let model = modelCatalogService.model(withID: modelID),
              model.installState.isReady,
              runtimeManager.activeModel == nil else { return }

        // Honour a sticky crash-loop guard from the previous launch.
        // The flag is cleared on every successful load, so a one-off
        // crash recovers on the second tap; only a persistent
        // load-time crash will leave the user on manual control.
        //
        // Also detects watchdog SIGKILL during termination (0x8BADF00D):
        // the flag is set at start, cleared at end. If the process is
        // killed in between — by an actual crash OR by the OS watchdog
        // failing to terminate gracefully — the flag survives.
        if let record = readAutoLoadGuardRecord() {
            UserDefaults.standard.removeObject(forKey: Self.autoLoadGuardKey)
            // Stale records (> 1 hour) are treated as cleared. A user
            // returning to the app a day later has likely freed memory,
            // updated iOS, or otherwise changed conditions; we should
            // try the load again rather than nag forever.
            let staleAfter: TimeInterval = 60 * 60
            let age = Date().timeIntervalSince(record.startedAt)
            if record.modelID == modelID && age < staleAfter {
                let log = Logger(subsystem: "HomeHub", category: "AppContainer")
                log.warning("autoLoadSelectedModel: previous-launch load of '\(modelID, privacy: .public)' did not complete (started \(Int(age))s ago) — skipping auto-load")
                lastAutoLoadCrash = AutoLoadCrash(modelID: modelID, occurredAt: .now)
                return
            } else if record.modelID == modelID {
                let log = Logger(subsystem: "HomeHub", category: "AppContainer")
                log.info("autoLoadSelectedModel: stale guard for '\(modelID, privacy: .public)' (age \(Int(age))s) — clearing and retrying")
            }
        }

        writeAutoLoadGuardRecord(.init(modelID: modelID, startedAt: .now))
        await runtimeManager.load(model)
        // Only clear when the load actually settled into .ready —
        // a load that failed cleanly (RuntimeError, no app crash)
        // still leaves us at a known-good place and the user can
        // retry, so clearing the flag is correct.
        if case .ready = runtimeManager.state {
            UserDefaults.standard.removeObject(forKey: Self.autoLoadGuardKey)
        } else if case .failed = runtimeManager.state {
            // Same logic — a typed failure is observable; only an app
            // termination justifies preserving the flag.
            UserDefaults.standard.removeObject(forKey: Self.autoLoadGuardKey)
        }
    }

    /// UserDefaults key for the crash-loop guard. The stored value is
    /// a JSON-encoded `AutoLoadGuardRecord` so we can keep both the
    /// model ID *and* a timestamp without inventing a sibling key.
    /// Internal so tests can assert the persisted shape without
    /// pulling in the whole AppContainer.
    static let autoLoadGuardKey = "com.homehub.app.autoLoadGuardRecord"

    /// Sticky marker written immediately before `runtime.load(...)` and
    /// cleared on settled state. If the process dies in between (real
    /// crash, watchdog kill, jetsam) the record survives and the next
    /// launch can detect the failed attempt. The timestamp lets us
    /// expire stale records so a load that crashed last week doesn't
    /// keep blocking auto-load forever.
    struct AutoLoadGuardRecord: Codable, Equatable {
        let modelID: String
        let startedAt: Date
    }

    /// Reads the guard record. Static so tests can call it against any
    /// `UserDefaults` (production code passes `.standard`); the
    /// instance helper below is the production entry point.
    static func readAutoLoadGuardRecord(
        from defaults: UserDefaults = .standard
    ) -> AutoLoadGuardRecord? {
        // Two-format read: prefer the new JSON record; fall back to the
        // pre-existing bare-string key for users upgrading mid-flight.
        // The legacy entry is migrated by being cleared on next clean
        // load — no separate migration pass needed.
        if let data = defaults.data(forKey: autoLoadGuardKey),
           let rec = try? JSONDecoder().decode(AutoLoadGuardRecord.self, from: data) {
            return rec
        }
        if let legacy = defaults.string(forKey: autoLoadGuardKey) {
            return AutoLoadGuardRecord(modelID: legacy, startedAt: .now)
        }
        return nil
    }

    static func writeAutoLoadGuardRecord(
        _ rec: AutoLoadGuardRecord,
        to defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(rec) else { return }
        defaults.set(data, forKey: autoLoadGuardKey)
    }

    private func readAutoLoadGuardRecord() -> AutoLoadGuardRecord? {
        Self.readAutoLoadGuardRecord()
    }

    private func writeAutoLoadGuardRecord(_ rec: AutoLoadGuardRecord) {
        Self.writeAutoLoadGuardRecord(rec)
    }

    /// Snapshot of the most recent crash-loop event. Published so the
    /// Models screen can surface a "Last auto-load crashed — load
    /// manually" banner, mirroring the pattern used for memory-pressure
    /// unloads.
    @Published private(set) var lastAutoLoadCrash: AutoLoadCrash?

    struct AutoLoadCrash: Equatable {
        let modelID: String
        let occurredAt: Date
    }

    /// Clears the crash banner once the user acknowledges it.
    func acknowledgeAutoLoadCrash() {
        lastAutoLoadCrash = nil
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

    /// Builds the active `WebSearchEngine` from settings.
    ///
    /// - When `searxngBaseURL` is configured, returns a `Fallback`
    ///   engine that tries SearXNG first and falls through to DDG when
    ///   SearXNG returns no results (down, misconfigured, query the
    ///   instance refuses to handle).
    /// - When no SearXNG URL is set (default), returns the standalone
    ///   DDG Lite scraper.
    ///
    /// The fallback shape means users who paste a SearXNG URL get its
    /// quality without losing offline-friendly DDG fallback when the
    /// instance is unavailable. Users who never touch the field keep
    /// working with DDG exactly like before.
    private func makeWebSearchEngine() -> any WebSearchEngine {
        let raw = settingsService.current.searxngBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let underlying: any WebSearchEngine = {
            guard !raw.isEmpty, let url = URL(string: raw) else {
                return DuckDuckGoLiteEngine()
            }
            return FallbackWebSearchEngine(
                primary: SearXNGEngine(baseURL: url),
                fallback: DuckDuckGoLiteEngine()
            )
        }()
        // Wrap the resolved engine in an LRU cache so repeated lookups
        // inside the 15-min window are network-free. The cache
        // forwards `displayName` so the model's observation still
        // reads "via DuckDuckGo" — caching is transparent at the
        // citation layer. Always-on (no settings flag): cache misses
        // behave identically to the un-cached engine, so there's no
        // user-visible regression to gate.
        return CachingWebSearchEngine(upstream: underlying)
    }

    /// Registers `WebSearchSkill` with the shared `SkillManager` iff
    /// the user has `WebSearch` in `AppSettings.enabledTools`. The
    /// engine is resolved via `makeWebSearchEngine()` so a configured
    /// SearXNG URL fronts the DDG fallback. Idempotent —
    /// re-registering with the same name replaces the engine, which is
    /// the path users hit when they paste / clear their SearXNG URL
    /// without toggling the WebSearch row.
    ///
    /// Called from `bootstrap()` after settings load, and from
    /// `setWebSearchEnabled(_:)` / `setSearxngBaseURL(_:)` whenever
    /// the user changes a field that affects the engine chain.
    private func registerWebSearchIfEnabled() async {
        let lowered = settingsService.current.enabledTools.map { $0.lowercased() }
        if lowered.contains("websearch") {
            await SkillManager.shared.register(WebSearchSkill(engine: makeWebSearchEngine()))
        }
        // FetchPage composes with WebSearch — same network trust
        // boundary, same prompt rail. Registered conditionally on its
        // own flag so a user who wants search results but no full-page
        // fetches (bandwidth, privacy) can still flip it off
        // independently in Settings.
        if lowered.contains("fetchpage") {
            await SkillManager.shared.register(FetchPageSkill())
        }
    }

    /// Generic toggle endpoint used by the Settings UI. Persists the
    /// allow-list change AND handles any side-effects for tools that
    /// need conditional registration (currently WebSearch — registered
    /// only when explicitly enabled, since its prompt-side privacy
    /// rail flips based on registration presence in `SkillManager`).
    ///
    /// Always-registered skills (Calculator, Calendar, …) need no
    /// side-effect here: the allow-list filter at call time already
    /// hides disabled tools from the prompt.
    func setToolEnabled(_ toolName: String, enabled: Bool) async {
        if toolName.lowercased() == "websearch" {
            await setWebSearchEnabled(enabled)
            return
        }
        var current = settingsService.current.enabledTools
        if enabled { current.insert(toolName) } else { current.remove(toolName) }
        await settingsService.set(\.enabledTools, to: current)
    }

    // MARK: - iCloud sync

    /// Toggles iCloud Drive sync for the persistent JSON store.
    ///
    /// Two-phase operation:
    ///   1. Copy every file from the current root (local or iCloud) to
    ///      the other root via `iCloudStorageBridge.migrate(...)`.
    ///   2. Persist the new preference so subsequent `FileStore()`
    ///      instantiations (cold launch) pick the new root.
    ///
    /// The currently-running `FileStore` keeps writing to its original
    /// root for the rest of this session — switching the live store's
    /// root would require coordinating with every actor mid-flight,
    /// which is much more invasive than the kill-and-respawn cold
    /// launch handles. The user sees a "Restart the app for sync to
    /// take effect" message in the Settings row when this returns.
    ///
    /// Migration is best-effort: any individual file copy that fails
    /// is logged and skipped (the user can re-toggle to retry). When
    /// iCloud is unavailable (no entitlement, signed-out, or container
    /// not provisioned in the developer portal), enabling the toggle
    /// is a silent no-op — the bridge degrades to local storage and
    /// no migration runs.
    ///
    /// - Parameter enabled: Whether iCloud sync should be active.
    /// - Returns: Telemetry tuple — copied / failed file counts and a
    ///   `requiresRelaunch` hint the Settings UI uses for its banner.
    @discardableResult
    func setICloudSyncEnabled(_ enabled: Bool) async -> (copied: Int, failed: Int, requiresRelaunch: Bool) {
        // Refuse the migration when iCloud isn't actually reachable —
        // we'd just no-op on resolveStorageDirectory anyway, and the
        // user would see the toggle flip back on next launch (because
        // the bridge re-resolves to local). Surface the unavailable
        // state by leaving the setting where it was.
        if enabled && !iCloudStorageBridge.isAvailable {
            let log = Logger(subsystem: "HomeHub", category: "AppContainer")
            log.notice("iCloud sync toggle: enable requested but iCloud unavailable — leaving preference at \(self.settingsService.current.iCloudSyncEnabled, privacy: .public)")
            return (0, 0, false)
        }

        // Resolve source / destination once, before we mutate the
        // setting — the bridge resolves directories based on the
        // preference, so a snapshot here keeps the migration honest.
        let currentRoot: URL
        if let fileStore = store as? FileStore {
            currentRoot = await fileStore.currentRootURL()
        } else {
            currentRoot = iCloudStorageBridge.resolveStorageDirectory(
                preferICloud: settingsService.current.iCloudSyncEnabled
            )
        }
        let targetRoot = iCloudStorageBridge.resolveStorageDirectory(preferICloud: enabled)

        // Persist the preference FIRST so a crash mid-migration leaves
        // the user in the "wanted state" — the next launch's FileStore
        // will resolve to `targetRoot` and the cold launch's bootstrap
        // re-runs the migration if any orphans remain. (The reverse
        // ordering would risk persisting `false` after a successful
        // copy, leaving data in iCloud the user thinks they enabled.)
        await settingsService.set(\.iCloudSyncEnabled, to: enabled)

        let result = try? await iCloudStorageBridge.migrate(from: currentRoot, to: targetRoot)
        let copied = result?.copied ?? 0
        let failed = result?.failed ?? 0

        let log = Logger(subsystem: "HomeHub", category: "AppContainer")
        log.info("iCloud sync toggle → \(enabled, privacy: .public): migrated \(copied, privacy: .public) item(s), \(failed, privacy: .public) failure(s)")

        // Restart hint surfaces in the Settings footer. The live store
        // keeps writing to its old root until cold launch picks up the
        // new preference — that's a stale-write hazard for a session
        // that lingers post-toggle (settings save lands in the old
        // location, mismatching the iCloud copy). One forced cold
        // launch eliminates the divergence.
        return (copied: copied, failed: failed, requiresRelaunch: true)
    }

    /// Updates the SearXNG base URL and re-registers WebSearch so the
    /// next chat turn uses the new engine chain. No-op when WebSearch
    /// is disabled — the engine won't be referenced until the user
    /// flips the row on, at which point `setWebSearchEnabled` will
    /// rebuild from the latest settings anyway.
    ///
    /// The URL is trimmed but not otherwise validated; an unreachable
    /// URL just means `SearXNGEngine.search` logs an error and falls
    /// through to DDG, so the worst case for a typo is "behaves like
    /// the WebSearch did before SearXNG was added".
    func setSearxngBaseURL(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        await settingsService.set(\.searxngBaseURL, to: trimmed)
        let isEnabled = settingsService.current.enabledTools
            .map { $0.lowercased() }
            .contains("websearch")
        guard isEnabled else { return }
        await SkillManager.shared.register(WebSearchSkill(engine: makeWebSearchEngine()))
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
            await SkillManager.shared.register(WebSearchSkill(engine: makeWebSearchEngine()))
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
    /// **Two-tier policy.** iOS level-1 warnings are hints, not commands —
    /// other on-device LLM apps stay loaded across the first one or two.
    /// We mirror that:
    ///   1. **Soft tier** (first warning in a 30 s window): drop the
    ///      embedding model, the KV-reuse `ChatSession`, and ask the
    ///      runtime to trim cheap caches via `trimMemoryCaches()`. Keep
    ///      the model weights resident. Typically reclaims 80–250 MB.
    ///   2. **Hard tier** (second warning in window, or
    ///      `os_proc_available_memory()` below `weights × 0.6`, or the
    ///      runtime is idle and the system keeps warning): full unload.
    ///   3. **Deferred** while a generation is mid-stream — interrupting
    ///      a streaming reply is worse UX than completing the turn and
    ///      unloading immediately after. The runtime's own pressure path
    ///      runs again when the next L1 warning arrives, which on a
    ///      genuinely tight device happens within a second.
    func handleMemoryPressure() async {
        memoryWarningCount += 1

        let now = Date()
        let withinDebounceWindow = lastMemoryPressureAt.map {
            now.timeIntervalSince($0) < Self.memoryPressureDebounceSeconds
        } ?? false
        lastMemoryPressureAt = now

        let availableBytes = RuntimeManager.availableMemoryBytes()
        let weightsBytes = runtimeManager.activeModel?.sizeBytes ?? 0
        let belowHardFloor: Bool = {
            guard let avail = availableBytes, weightsBytes > 0 else { return false }
            return Double(avail) < Double(weightsBytes) * 0.6
        }()

        let isGenerating = runtimeManager.isGenerating
        let escalate = (memoryWarningCount > 1 && withinDebounceWindow) || belowHardFloor

        let log = Logger(subsystem: "HomeHub", category: "AppContainer")
        log.warning("Memory pressure #\(self.memoryWarningCount) avail=\(availableBytes ?? -1) weights=\(weightsBytes) within=\(withinDebounceWindow, privacy: .public) hardFloor=\(belowHardFloor, privacy: .public) busy=\(isGenerating, privacy: .public) escalate=\(escalate, privacy: .public)")

        // Surface to Diagnostics. Snapshotted *before* the soft trim so
        // the reader sees the values that drove the decision, not the
        // post-trim state. `escalatedToHard` reflects what *will*
        // happen below — the guard at the bottom doesn't change this.
        let snapshot = PressureEventSnapshot(
            occurredAt: now,
            availableBytes: availableBytes,
            weightsBytes: weightsBytes,
            inDebounceWindow: withinDebounceWindow,
            belowHardFloor: belowHardFloor,
            wasGenerating: isGenerating,
            escalatedToHard: escalate && !isGenerating
        )
        lastPressureEvent = snapshot
        // Newest-first append + bounded retention via the shared
        // helper — keeps the live code and the unit tests on a single
        // implementation. `@Published` triggers SwiftUI updates; we're
        // already on the main actor so this is cheap.
        Self.appendBoundedPressure(snapshot, to: &pressureHistory)
        // Mirror the event into the OOM breadcrumb log so a post-jetsam
        // tail of the log shows pressure events interleaved with load /
        // generate landmarks. MetricKit's diagnostic delivery is ~24 h
        // behind reality; pressure events are real-time and the most
        // useful early-warning signal for "the next jetsam is coming".
        OOMTelemetryService.shared.breadcrumb(
            snapshot.escalatedToHard ? "pressure.hard" : (snapshot.wasGenerating ? "pressure.deferred" : "pressure.soft"),
            context: [
                "availableMB": snapshot.availableBytes.map { "\($0 / 1_048_576)" } ?? "?",
                "weightsMB":   "\(snapshot.weightsBytes / 1_048_576)",
                "warningCount": "\(memoryWarningCount)",
                "inDebounce":  "\(withinDebounceWindow)",
                "belowFloor":  "\(belowHardFloor)"
            ]
        )

        // Soft tier: always trim cheap caches. Embedding model + runtime
        // session scratch combined usually frees 80–250 MB on the first
        // warning, often enough to keep the model resident.
        await embeddingService.unload()
        await runtimeManager.handleSoftMemoryPressure()
        // Markdown attributed-string LRU is a few MB at most but it's
        // free to drop and the next-render rebuild is fast. Doing it on
        // every L1 keeps the eviction policy honest (the user is in
        // pressure right now — nothing in the cache is "hot enough" to
        // earn its keep).
        InlineMarkdownText.purgeCache()

        // Hard tier — escalate only when the policy says so AND the
        // runtime isn't mid-token. If it's busy, leave the unload to
        // the next L1 (the OS keeps sending them when memory is truly
        // tight, so we don't lose the signal).
        guard escalate, !isGenerating else { return }

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

    /// Wall-clock of the most recent `scenePhase == .background`
    /// transition. Read by `ConversationService` at stream-finish
    /// time to detect "did this generation cross a background event?"
    /// — if so the count below ticks and the user gets a quiet hint
    /// that iOS let the model finish off-screen.
    @Published private(set) var lastBackgroundedAt: Date?

    /// Lifetime count of generations that ran across a background
    /// transition and still completed successfully. Visible in
    /// `DeveloperDiagnosticsView` so users (and the dev) can confirm
    /// that the iOS background-task assertion is actually buying us
    /// the extra 30s the entitlement promises. A repeated zero here
    /// while users report "my reply got cut off on lock" is a strong
    /// signal that backgrounding is killing streams earlier than
    /// expected — likely a `BGProcessingTask` config issue.
    @Published private(set) var backgroundGenerationCompletions: Int = 0

    /// Records a successful background-spanning generation completion.
    /// Public so `ConversationService` can call it from its stream
    /// epilogue without needing to plumb a new telemetry channel.
    func recordBackgroundGenerationCompletion() {
        backgroundGenerationCompletions += 1
    }

    /// Sliding-window debounce for the two-tier pressure policy. iOS
    /// can deliver bursts of L1 warnings ~1 s apart when the device is
    /// truly tight; we want the *second* one in that burst to escalate
    /// to a hard unload. A 30 s window is long enough to catch a real
    /// memory-tight situation, short enough that a single warning from
    /// switching apps doesn't leave the device "primed" for an unload
    /// hours later.
    private var lastMemoryPressureAt: Date?
    private static let memoryPressureDebounceSeconds: TimeInterval = 30

    /// Structured snapshot of the most recent memory-pressure decision.
    /// Surfaced in `DeveloperDiagnosticsView` so the user can correlate
    /// "I just saw a banner" with the policy inputs without needing
    /// Xcode attached. Updated on every L1 warning regardless of tier.
    @Published private(set) var lastPressureEvent: PressureEventSnapshot?

    /// Bounded history of recent pressure events, newest first. Drives
    /// the "Pressure history" disclosure in Diagnostics so the user can
    /// see *trend* ("8× soft, 1× hard in the last hour") instead of
    /// just the most recent line. Capped at `pressureHistoryCap` so a
    /// long session under chronic pressure can't grow this unbounded —
    /// when the cap is reached the oldest entry is dropped.
    @Published private(set) var pressureHistory: [PressureEventSnapshot] = []
    /// Cap is internal (not private) so tests can assert the contract
    /// at the same value the runtime enforces — duplicating the
    /// number in test code would let drift hide a regression.
    static let pressureHistoryCap = 20

    /// Bounded insert used by `handleMemoryPressure(...)` to keep the
    /// ringbuffer invariants in one place. Newest-first ordering plus
    /// hard cap (`pressureHistoryCap`). Exposed as a static so tests
    /// can exercise it without bootstrapping a full container.
    static func appendBoundedPressure(
        _ snapshot: PressureEventSnapshot,
        to history: inout [PressureEventSnapshot],
        cap: Int = pressureHistoryCap
    ) {
        history.insert(snapshot, at: 0)
        if history.count > cap {
            history.removeLast(history.count - cap)
        }
    }

    /// Wipes the in-memory pressure history and the "last event"
    /// snapshot. Used by Diagnostics → "Clear" so a tester can start
    /// fresh before reproducing a bug. The warning *count* is left
    /// alone (it's the only running total we keep across resets).
    func clearPressureHistory() {
        pressureHistory.removeAll()
        lastPressureEvent = nil
    }

    struct PressureEventSnapshot: Equatable {
        let occurredAt: Date
        /// `os_proc_available_memory()` at the moment of the warning.
        /// `nil` when the sysctl returned 0 (rare; e.g. simulator).
        let availableBytes: Int64?
        /// `activeModel?.sizeBytes` at the moment of the warning.
        /// 0 when no model was loaded.
        let weightsBytes: Int64
        /// `true` if the warning landed inside the debounce window.
        let inDebounceWindow: Bool
        /// `true` if `available < weights × 0.6`.
        let belowHardFloor: Bool
        /// `true` if the runtime was mid-token-stream.
        let wasGenerating: Bool
        /// `true` if the policy escalated to a hard unload. `false` for
        /// soft-tier (trim-only) responses.
        let escalatedToHard: Bool
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
        // Knowledge Base ingest scheduler watches the same lifecycle
        // events: schedule a BG processing task on `.background`,
        // resume foreground drain on `.active`. Side-effect-only —
        // safe to call alongside the runtime path below.
        await knowledgeBaseService.handleScenePhase(phase)

        switch phase {
        case .background:
            // Stamp the transition timestamp BEFORE any teardown work.
            // ConversationService reads this in its stream epilogue
            // to detect whether the in-flight generation crossed a
            // background event; doing it first means a fast stream
            // that finishes in the same micro-second as the
            // background transition still gets counted correctly.
            lastBackgroundedAt = .now
            if let unloaded = await runtimeManager.handleBackground() {
                let time = DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .medium)
                lastUnloadNotification = "\(time) – '\(unloaded.displayName)' unloaded (app backgrounded)"
                // Note: we DON'T set `pendingUnloadNotice` for the
                // app-background case — the next foreground transition
                // (`.active` below) auto-reloads the model, so the user
                // never sees the chat in a broken state and a banner
                // would only flash on screen for a fraction of a second.
            }
            // Force any autosave-pending writes to disk before iOS
            // suspends us. Otherwise a chat turn that finished
            // 100 ms before backgrounding can sit in the autosave
            // debounce window until the next foreground — and a
            // jetsam in between loses it. Cheap when there's nothing
            // pending (no-op on `hasChanges == false`).
            await store.flushPendingChanges()
            // Auto-episodize idle conversations as a fire-and-forget
            // task. Runs *after* flushPendingChanges so any in-flight
            // user turn is persisted before we summarize its
            // conversation. Doesn't block backgrounding — iOS gives us
            // ~5 s before it forces suspend, and the episode write is
            // bounded by the auto-summarizer's own runtime. If iOS
            // suspends mid-write, the partial episode just isn't
            // persisted; the next background pass picks it up again.
            Task { [weak self] in
                await self?.conversationService.autoEpisodizeIdleConversations()
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
            // Re-validate the HF token in the background if the last
            // successful validation is older than the stale threshold.
            // Tokens can be revoked or expire upstream without warning;
            // catching it here means the user finds out at app launch
            // rather than 30 s into a multi-GB download. Fire-and-
            // forget — the result lands in the `huggingFaceTokenStatus`
            // banner the next time Settings or a gated download is
            // attempted, never blocks the foreground transition.
            Task { await refreshHFTokenStatusIfStale() }

            // MLX cache hygiene — throttled to at most once every 24 h
            // per running process so the disk walk only fires when it
            // could plausibly find new work to do. Bootstrap already
            // runs the same pass on cold-launch; this catches users who
            // keep the app suspended for days between sessions and
            // accumulate broken caches in the background. Detached so
            // the I/O can't stall the foreground transition.
            Task { [weak self] in
                await self?.runMLXCacheHygieneIfStale()
            }
        default:
            break
        }
    }

    /// `nil` until the first re-validation completes. Once set,
    /// reflects the freshest known state of the stored HF token —
    /// surfaced in Diagnostics and used by the gated-download path to
    /// route the user to Settings before a doomed attempt.
    @Published private(set) var huggingFaceTokenStatus: HFTokenStatus?

    enum HFTokenStatus: Equatable {
        /// Validated successfully. `at` is wall-clock time of the probe.
        case valid(username: String, at: Date)
        /// HF rejected the token (401/403). Either revoked, expired,
        /// or pasted wrong. The Settings UI should highlight the row.
        case invalid(at: Date)
        /// Couldn't reach HF — token might still be fine. Treated as
        /// "don't show the alarm bell" by the UI; user retries on
        /// better network.
        case networkError(at: Date, detail: String)
    }

    /// How old the last successful validation can be before we re-probe
    /// on foreground. A week is a sane default — HF tokens don't
    /// silently rotate, but users sometimes revoke them weeks later
    /// during a clean-up pass and we want to catch that. Configurable
    /// only at compile time; expose it if users complain.
    private static let hfTokenStaleThreshold: TimeInterval = 7 * 24 * 60 * 60

    /// Minimum gap between two foreground-triggered token refreshes.
    /// Prevents the "user toggles to Notification Center and back
    /// every 10 s while doom-scrolling" case from blasting HF with
    /// repeated whoami probes — most calls would already short-circuit
    /// on the stale-threshold check anyway, but this is the belt-and-
    /// braces for the *first* foreground after a stale verification:
    /// without it, three quick foregrounds in 5 s = three identical
    /// network probes in flight. 5 minutes is long enough to coalesce
    /// scroll-back-and-forth, short enough that a user who left the
    /// app for lunch (~hour) always gets a fresh check.
    private static let hfRefreshMinInterval: TimeInterval = 5 * 60

    /// Wall-clock of the most recent foreground-triggered HF refresh.
    /// Explicit user actions (the Settings "Re-ověřit" button) bypass
    /// this gate — they go through `forceRevalidateHFToken()` directly.
    private var lastHFRefreshAt: Date?

    /// Minimum gap between two foreground-triggered MLX cache hygiene
    /// runs. 24 h matches the natural cadence of someone using the app
    /// daily: the bootstrap pass at cold launch covers the rare case,
    /// and this catches users who keep the app suspended for multiple
    /// days. Tighter than 24 h would burn disk I/O for no payoff (the
    /// cache state doesn't change while the app is suspended).
    private static let mlxHygieneMinInterval: TimeInterval = 24 * 60 * 60

    /// Wall-clock of the most recent foreground-triggered cache pass.
    /// The bootstrap pass doesn't update this — they're separate code
    /// paths and the bootstrap one always runs unconditionally.
    private var lastMLXHygieneAt: Date?

    /// Foreground-triggered MLX cache hygiene gated by `mlxHygieneMinInterval`.
    /// Repeated foreground transitions inside the throttle window are
    /// no-ops; the first call after the window elapsed runs the full
    /// orphan + broken-cache pass via `runMLXCacheHygiene()`. Sized to
    /// pair with the existing `refreshHFTokenStatusIfStale` pattern.
    func runMLXCacheHygieneIfStale() async {
        if let last = lastMLXHygieneAt,
           Date().timeIntervalSince(last) < Self.mlxHygieneMinInterval {
            return
        }
        lastMLXHygieneAt = Date()
        let result = await modelDownloadService.runMLXCacheHygiene()
        if result.orphans > 0 || result.broken > 0 {
            let log = Logger(subsystem: "HomeHub", category: "AppContainer")
            log.info("Foreground MLX hygiene: \(result.orphans, privacy: .public) orphan(s) + \(result.broken, privacy: .public) broken cache(s) removed, reclaimed \(result.reclaimedBytes, privacy: .public) B")
        }
    }

    /// Runs the re-validation iff the stored verification is older than
    /// `hfTokenStaleThreshold` (or has never been recorded at all even
    /// though a token is present — covers the "user typed it but
    /// hasn't validated since a hotfix shipped" upgrade case).
    /// No-op when no token is configured.
    ///
    /// Rate-limited via `hfRefreshMinInterval` — repeated foreground
    /// transitions within 5 minutes don't re-probe HF a second time.
    /// The published status from the prior probe stays accurate, so
    /// the UI doesn't briefly flicker through "loading" states on
    /// every scroll-back-to-app.
    func refreshHFTokenStatusIfStale() async {
        guard let token = HFTokenStore.load(), !token.isEmpty else {
            // No token → clear any stale status so the UI doesn't
            // render "valid" after the user cleared their token in
            // a previous session.
            huggingFaceTokenStatus = nil
            return
        }
        if let last = lastHFRefreshAt,
           Date().timeIntervalSince(last) < Self.hfRefreshMinInterval {
            // Rate limiter: skip the probe entirely. The published
            // status from the previous refresh stays — that's the
            // freshest information we have, and re-running the probe
            // wouldn't change the answer in <5 min anyway.
            return
        }
        lastHFRefreshAt = Date()

        let last = HFTokenStore.lastVerification()
        if let last, Date().timeIntervalSince(last.at) < Self.hfTokenStaleThreshold {
            // Fresh enough — surface the cached state without a
            // network probe so the UI knows what we believe.
            huggingFaceTokenStatus = .valid(username: last.username, at: last.at)
            return
        }
        await forceRevalidateHFToken()
    }

    /// Unconditional re-validation. Used by the Settings "Re-ověřit"
    /// button after the user rotates their token on huggingface.co
    /// and wants confirmation. Updates `huggingFaceTokenStatus` for
    /// every outcome (including `.invalid` / `.networkError`) — unlike
    /// `refreshHFTokenStatusIfStale`, this path NEVER reads the
    /// cached verification, so a stored-but-revoked token will be
    /// correctly downgraded to `.invalid` even if the cached metadata
    /// still says it was valid yesterday.
    @discardableResult
    func forceRevalidateHFToken() async -> HuggingFaceAPIClient.TokenValidation? {
        guard let token = HFTokenStore.load(), !token.isEmpty else {
            huggingFaceTokenStatus = nil
            return nil
        }
        let result = await HuggingFaceAPIClient.validateToken(token)
        switch result {
        case .valid(let username):
            HFTokenStore.recordVerification(username: username)
            huggingFaceTokenStatus = .valid(username: username, at: Date())
        case .invalid:
            huggingFaceTokenStatus = .invalid(at: Date())
        case .networkError(let detail):
            huggingFaceTokenStatus = .networkError(at: Date(), detail: detail)
        }
        return result
    }

    // MARK: - Factories

    /// Production wiring. Uses `FileStore` for persistence and `MLXRuntime`
    /// as the primary backend. `LlamaCppRuntime` is only constructed when the
    /// build opts in to llama.cpp via `HOMEHUB_LLAMA_RUNTIME` (default: off).
    static let shared = AppContainer.live()

    static func live() -> AppContainer {
        // Kick off the OOM breadcrumb pipeline before any other
        // initialisation so even a panic during runtime construction
        // gets a `session.start` landmark in the persisted log. The
        // service is a `@MainActor` singleton — `start()` is
        // idempotent so a second call (e.g. from a future test seam)
        // is a no-op.
        OOMTelemetryService.shared.start()

        let mlx = makeMLXRuntime()

        #if HOMEHUB_LLAMA_RUNTIME
        let llama = LlamaCppRuntime()
        let runtime: any LocalLLMRuntime = RoutingRuntime(llamaCpp: llama, mlx: mlx)
        #else
        let runtime: any LocalLLMRuntime = RoutingRuntime(mlx: mlx)
        #endif

        let store: any Store
        #if HOMEHUB_SWIFTDATA
        do {
            store = try SwiftDataStore()
        } catch {
            // Schema migration failure or on-disk corruption. Fall back to
            // FileStore so the app remains usable; the user's model data is
            // preserved on disk and may become accessible again after an app
            // update that handles the migration.
            let log = Logger(subsystem: "HomeHub", category: "AppContainer")
            log.error("SwiftDataStore init failed, falling back to FileStore: \(error.localizedDescription, privacy: .public)")
            store = FileStore()
        }
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

        // Broken-cache recovery: when MLXRuntime refuses to load a
        // model because the on-disk cache is missing weights /
        // tokenizer / config, flip the catalog back to `.notInstalled`
        // and remove the broken cache directory. The Models view will
        // re-render with a Download CTA on the next state push;
        // without this, the user sees a load-failed banner over a
        // row that still says "Installed", which is confusing and
        // requires manual Delete + Download.
        container.runtimeManager.onBrokenCacheDetected = { [weak container] model, _ in
            guard let container else { return }
            container.modelCatalogService.setInstallState(.notInstalled, for: model.id)
            // Wipe the MLX cache so the next Download starts clean.
            // GGUF models don't have a cache directory — `remove(_:)`
            // is a no-op for missing files. Detached because we're
            // already inside a load-failure log line and don't want
            // disk I/O to delay the state mutation above.
            Task { [weak container] in
                guard let container else { return }
                if model.format == .mlx, let repoId = model.repoId {
                    try? await container.localModelService.removeMLXCache(for: repoId)
                } else {
                    try? await container.localModelService.remove(model.id)
                }
            }
        }

        // Plumb the GGUF metadata cache into the llama.cpp runtime so it
        // can read architecture-driven chat templates + native context
        // limits the same way `RuntimeManager` already does for logging.
        #if HOMEHUB_LLAMA_RUNTIME
        llama.ggufMetadataProvider = { [weak container] modelID in
            container?.modelCatalogService.metadata(for: modelID)
        }
        #endif

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

    // MARK: - Test seam

    /// Constructs the MLX runtime, swapping in `FakeMLXLoader` when launched
    /// with `--use-fake-mlx-loader`. The argument and the `MLX_LOAD_BEHAVIOR`
    /// env var are how UI tests (and manual repro scripts) drive deterministic
    /// load progress / load failures without hitting the real Hub downloader
    /// or Metal compile. Production launches never pass the argument, so this
    /// branch is dead code at runtime in shipped builds.
    private static func makeMLXRuntime() -> MLXRuntime {
        let info = ProcessInfo.processInfo
        guard info.arguments.contains("--use-fake-mlx-loader") else {
            return MLXRuntime()
        }
        let fake = FakeMLXLoader()
        switch info.environment["MLX_LOAD_BEHAVIOR"] {
        case "failure":
            fake.behavior = .failure("Simulated loading failure")
        case "slow":
            fake.behavior = .slowProgress(steps: 10, delay: 0.1)
        default:
            fake.behavior = .success
        }
        return MLXRuntime(loader: fake)
    }
}
