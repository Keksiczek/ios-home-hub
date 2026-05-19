import Combine
import SwiftUI

// MARK: - ModelBrowserStatus

/// Collapsed view-layer status for a single model row.
///
/// Priority order in `ModelBrowserViewModel.computeStatus(for:)`:
/// 1. `runtime.activeModel?.id == model.id`              → `.loaded`
/// 2. `runtime.state == .loading(modelID: model.id)`     → `.loading`
/// 3. `runtime.state == .unloading` (and we know which)  → `.unloading`
/// 4. `runtime.state == .failed(model.id, reason)`       → `.loadFailed`
/// 5. `model.installState` → one of the remaining cases
enum ModelBrowserStatus: Equatable {

    /// No local file; download has not started.
    case notInstalled

    /// Transport is in-flight. When `progress < 0.001` AND `phase == .downloading`
    /// the download is using chunked encoding (no Content-Length); the UI should
    /// show an indeterminate spinner rather than an empty progress bar.
    case downloading(progress: Double, phase: ModelDownloadService.DownloadPhase)

    /// Background URLSession task is alive (survived OS kill + relaunch) but the
    /// in-process `DownloadState` has not yet materialised. Show a spinner + label.
    case reconnecting

    /// File on disk; not held in runtime memory.
    case installed

    /// `RuntimeManager.state == .loading(modelID:)` for this specific model.
    case loading

    /// This model is the active runtime model.
    case loaded

    /// `RuntimeManager.state == .unloading` while this model was the active one.
    case unloading

    /// A previous download ended with an error.
    case downloadFailed(reason: String)

    /// A previous `runtime.load(_:)` attempt ended with an error.
    case loadFailed(reason: String)
}

// MARK: - ModelBrowserItem

/// A single row in the model browser, combining catalog metadata with
/// the collapsed `ModelBrowserStatus` computed from three sources.
struct ModelBrowserItem: Identifiable, Equatable {
    var id: String { model.id }
    let model: LocalModel
    let status: ModelBrowserStatus
    let hasResumeData: Bool
    /// Non-nil while an MLX model is loading weights into memory for this row.
    let mlxLoadProgress: MLXLoadProgress?
    /// Live memory-oracle verdict for this device + the user's current
    /// performance profile. `nil` when the catalog entry has no
    /// `sizeBytes` known yet (rare — most catalog entries pin it). The
    /// view layer renders this as a "fits / tight / won't-fit" badge so
    /// users see compatibility before tapping Download, instead of
    /// discovering it on the confirm sheet five seconds later.
    let feasibility: RuntimeManager.LoadFeasibility?
    /// Whether each affordance should be enabled. Computed in
    /// `ModelBrowserViewModel.recompute()` from the combined download +
    /// runtime state so the view layer doesn't have to re-derive it.
    let actions: Actions

    struct Actions: Equatable {
        /// Download / Resume button. Disabled when a transport is already
        /// in flight or the file is already on disk.
        let canDownload: Bool
        /// Load button. Disabled when another model is loading / unloading
        /// (the runtime serialises load operations) or when this model is
        /// already the active one.
        let canLoad: Bool
        /// Unload button. Disabled unless this exact model is the active
        /// runtime model in a stable (.ready) state.
        let canUnload: Bool
    }
}

// MARK: - ModelBrowserSection

struct ModelBrowserSection: Identifiable {
    enum Kind: Hashable { case onDevice, available }

    var id: Kind { kind }
    let kind: Kind
    let items: [ModelBrowserItem]

    var headerText: String {
        switch kind {
        case .onDevice:  return "On this device"
        case .available: return "Available to download"
        }
    }

    var footerText: String {
        switch kind {
        case .onDevice:  return ""  // filled by the view (needs live disk stats)
        case .available: return "Models run entirely on this device. Sizes shown are compressed quantisations that fit in device RAM."
        }
    }
}

extension ModelBrowserSection: Equatable {
    static func == (lhs: ModelBrowserSection, rhs: ModelBrowserSection) -> Bool {
        lhs.kind == rhs.kind && lhs.items == rhs.items
    }
}

// MARK: - ModelBrowserViewModel

/// Thin view-model for the Model Browser screen.
///
/// Subscribes to catalog + download + runtime changes via Combine, debounces
/// at 50 ms to avoid rebuilding the section list on every 10 Hz progress tick,
/// and collapses multi-source state into `ModelBrowserStatus` for each row.
///
/// ## Lifecycle
///
/// Create with `@StateObject`, then call `connect(catalog:downloads:runtime:)`
/// from `.onAppear`. The `isConnected` guard makes it safe to call repeatedly.
@MainActor
final class ModelBrowserViewModel: ObservableObject {

    @Published private(set) var sections: [ModelBrowserSection] = []

    enum BackendFilter: String, CaseIterable, Identifiable {
        case all = "Vše"
        case mlx = "MLX"
        case gguf = "GGUF"
        var id: String { rawValue }
    }

    enum CompatibilityFilter: String, CaseIterable, Identifiable {
        case all = "Všechny"
        case iPhoneSafe = "iPhone friendly"
        var id: String { rawValue }
    }

    enum SourceFilter: String, CaseIterable, Identifiable {
        case curated = "Doporučené"
        case huggingFace = "Hugging Face"
        var id: String { rawValue }
    }

    @Published var selectedBackend: BackendFilter = .all {
        didSet { recompute() }
    }
    @Published var selectedCompatibility: CompatibilityFilter = .all {
        didSet { recompute() }
    }
    @Published var selectedSource: SourceFilter = .curated {
        didSet { recompute() }
    }

    @Published private(set) var isSearchingHF = false
    @Published var hfError: String? = nil
    private var rawHFModels: [LocalModel] = []
    /// In-flight fetch task. Cancelled and replaced whenever the
    /// query/backend changes so two parallel `.task(id:)` triggers
    /// (search-text vs source-change) don't race and overwrite each
    /// other with stale results.
    private var hfFetchTask: Task<Void, Never>?

    // Services – assigned once by connect().
    private weak var catalog:   ModelCatalogService?
    private weak var downloads: ModelDownloadService?
    private weak var runtime:   RuntimeManager?
    private weak var settings:  SettingsService?

    private var cancellables: Set<AnyCancellable> = []
    private var isConnected = false

    init() {}

    // MARK: - Connect

    /// Wires the Combine pipeline to the three service objects and performs an
    /// initial synchronous `recompute()` so the first render is correct.
    ///
    /// Idempotent — safe to call from `.onAppear` (fires on every re-appearance).
    func connect(
        catalog:   ModelCatalogService,
        downloads: ModelDownloadService,
        runtime:   RuntimeManager,
        settings:  SettingsService
    ) {
        guard !isConnected else { return }
        isConnected = true

        self.catalog   = catalog
        self.downloads = downloads
        self.runtime   = runtime
        self.settings  = settings

        // Synchronous initial pass — sections is populated before the next render.
        recompute()

        // Re-compute whenever any of the four sources publishes a change.
        // Settings is included so toggling the performance profile in the
        // sidebar immediately updates every fits/tight badge — previously
        // the badge would stay stale until the next catalog/runtime tick.
        Publishers.Merge4(
            catalog.objectWillChange  .map { _ in () }.eraseToAnyPublisher(),
            downloads.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            runtime.objectWillChange  .map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange .map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
        .sink { [weak self] _ in self?.recompute() }
        .store(in: &cancellables)
    }

    // MARK: - Recompute

    private func recompute() {
        guard let catalog, let downloads, let runtime else { return }

        let activeModelID   = runtime.activeModel?.id
        let runtimeState    = runtime.state
        let mlxProgress     = runtime.mlxLoadProgress
        let activeDownloads = downloads.active
        // The memory oracle reads the user's performance profile.
        // Fall back to `.balanced` when settings isn't connected yet
        // (very brief window during `init` → `connect`).
        let performanceProfile = settings?.current.performanceProfile ?? .balanced

        // During an explicit unload, `activeModel` is still set while
        // state == .unloading.  During a load-that-first-unloads, `activeModel`
        // is cleared before state becomes .unloading, so unloadingID is nil.
        let unloadingID: String?
        if case .unloading = runtimeState { unloadingID = runtime.activeModel?.id }
        else                              { unloadingID = nil }

        let sourceModels = selectedSource == .curated ? catalog.models : rawHFModels

        let newSections = buildSections(
            models:         sourceModels,
            activeModelID:  activeModelID,
            runtimeState:   runtimeState,
            unloadingID:    unloadingID,
            mlxProgress:    mlxProgress,
            activeDownloads: activeDownloads,
            downloads:      downloads,
            performanceProfile: performanceProfile
        )

        // Avoid spurious SwiftUI diffing passes when nothing actually changed.
        if newSections != sections { sections = newSections }
    }

    /// Fetches models from Hugging Face based on the query. Auto-scopes
    /// the search to a backend-appropriate author when no query is given
    /// (`mlx-community` for MLX, `bartowski` for GGUF) so the catalog
    /// returns repos the mapper can actually consume. Free-text search
    /// is left unscoped — that's the explicit user-intent path. Any
    /// in-flight fetch is cancelled before a new one starts so racing
    /// `.task(id:)` triggers can't overwrite each other with stale
    /// results.
    func fetchDynamicCatalog(query: String?) {
        guard isConnected else { return }
        hfFetchTask?.cancel()

        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearch = !(trimmed?.isEmpty ?? true)
        let backend  = selectedBackend
        let memoryProfile = DeviceMemoryProvider.shared.profile

        isSearchingHF = true
        hfError = nil

        hfFetchTask = Task { [weak self] in
            defer { Task { @MainActor in self?.isSearchingHF = false } }
            do {
                let items = try await HuggingFaceAPIClient.fetchPopularModels(
                    query:  isSearch ? trimmed : nil,
                    author: isSearch ? nil : Self.defaultAuthor(for: backend)
                )
                if Task.isCancelled { return }
                let mapped = items.map { item -> LocalModel in
                    var model = HFModelMapper.mapToLocalModel(item: item)
                    model.contextLength = ModelCatalogService.adjustContextLength(
                        base: model.contextLength,
                        family: model.family,
                        recommendedFor: model.recommendedFor,
                        memoryProfile: memoryProfile
                    )
                    return model
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    self.rawHFModels = mapped
                    self.recompute()
                }
            } catch is CancellationError {
                // Superseded by a newer fetch — silently drop.
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.hfError = error.localizedDescription
                    self.rawHFModels = []
                    self.recompute()
                }
            }
        }
    }

    /// Default author scope when no query is provided. Picks repos
    /// whose layout the `HFModelMapper` can actually parse — generic
    /// HF repos rarely conform to MLX/GGUF on-device requirements.
    private static func defaultAuthor(for backend: BackendFilter) -> String {
        switch backend {
        case .gguf: return "bartowski"
        case .mlx, .all: return "mlx-community"
        }
    }

    private func buildSections(
        models:          [LocalModel],
        activeModelID:   String?,
        runtimeState:    RuntimeManager.State,
        unloadingID:     String?,
        mlxProgress:     MLXLoadProgress?,
        activeDownloads: [String: ModelDownloadService.DownloadState],
        downloads:       ModelDownloadService,
        performanceProfile: PerformanceProfile
    ) -> [ModelBrowserSection] {
        guard let catalog = catalog else { return [] }
        
        var onDevice:  [ModelBrowserItem] = []
        var available: [ModelBrowserItem] = []

        // Snapshot `os_proc_available_memory()` once per recompute so
        // every row in a single rebuild compares against the same
        // headroom number. Without this, the oracle would invoke the
        // sysctl per-model and rows could disagree by a few MB just
        // due to natural memory churn between rapid calls — confusing
        // when the user sees "fits" on one row and "tight" on a
        // neighbour with similar size.
        let availableMemory = RuntimeManager.availableMemoryBytes()

        // 1. Reconcile HF search models against local catalog to get installed states
        var resolvedModels = [LocalModel]()
        for model in models {
            if let local = catalog.models.first(where: { $0.id == model.id }) {
                resolvedModels.append(local)
            } else {
                resolvedModels.append(model)
            }
        }

        // 2. Apply Backend Filter
        switch selectedBackend {
        case .all:
            break
        case .mlx:
            resolvedModels = resolvedModels.filter { $0.backend == .mlx }
        case .gguf:
            resolvedModels = resolvedModels.filter { $0.backend == .llamaCpp }
        }

        // 3. Apply Compatibility Filter
        switch selectedCompatibility {
        case .all:
            break
        case .iPhoneSafe:
            resolvedModels = resolvedModels.filter { $0.recommendedFor.contains(.iPhone) }
        }

        for model in resolvedModels {
            let status = computeStatus(
                model:           model,
                activeModelID:   activeModelID,
                runtimeState:    runtimeState,
                unloadingID:     unloadingID,
                activeDownloads: activeDownloads
            )
            let actions = computeActions(
                model:          model,
                status:         status,
                runtimeState:   runtimeState,
                activeModelID:  activeModelID
            )
            let feasibility = RuntimeManager.evaluateFeasibility(
                for:       model,
                profile:   performanceProfile,
                available: availableMemory
            )
            let item = ModelBrowserItem(
                model:           model,
                status:          status,
                hasResumeData:   downloads.hasResumeData(for: model.id),
                mlxLoadProgress: mlxProgress?.modelID == model.id ? mlxProgress : nil,
                feasibility:     feasibility,
                actions:         actions
            )
            if case .notInstalled = status { available.append(item) }
            else                           { onDevice.append(item) }
        }

        // Sort the "Available to download" section so the user sees
        // compatible models first. The previous render kept catalog
        // declaration order which buried Llama 3.2 1B (safe on every
        // iPhone) beneath Gemma 3n (won't-fit on 4 GB phones). Stable
        // sort by feasibility rank then by size — within each
        // compatibility tier the smaller model wins, which doubles as
        // a "try the lightest one first" hint for new users.
        available.sort { lhs, rhs in
            let lhsRank = Self.feasibilityRank(lhs.feasibility)
            let rhsRank = Self.feasibilityRank(rhs.feasibility)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.model.sizeBytes < rhs.model.sizeBytes
        }

        var result: [ModelBrowserSection] = []
        if !onDevice.isEmpty  { result.append(.init(kind: .onDevice,  items: onDevice)) }
        if !available.isEmpty { result.append(.init(kind: .available, items: available)) }
        return result
    }

    /// Maps a load-feasibility verdict to a sort rank for the
    /// available-section ordering. Lower rank = surface earlier.
    /// `nil` (oracle declined to evaluate — typically no `sizeBytes`
    /// on the catalog entry) sorts between `.safe` and `.risky`: we
    /// don't have a verdict, but we also have no positive evidence
    /// the model won't fit, so we keep it visible above the
    /// definitely-won't-fit tier.
    private static func feasibilityRank(_ verdict: RuntimeManager.LoadFeasibility?) -> Int {
        switch verdict {
        case .safe?:        return 0
        case nil:           return 1
        case .risky?:       return 2
        case .cannotLoad?:  return 3
        }
    }

    /// Single place that decides which affordances each row can offer.
    /// Mirrors the runtime serialisation invariant in `RuntimeManager`:
    /// only one load or unload may be in flight at a time, so while any
    /// model is `.loading` or `.unloading` every other row's Load button
    /// is disabled.
    private func computeActions(
        model:         LocalModel,
        status:        ModelBrowserStatus,
        runtimeState:  RuntimeManager.State,
        activeModelID: String?
    ) -> ModelBrowserItem.Actions {
        // Build-time gate: if the backend isn't linked, nothing applies.
        guard model.isUsableInThisBuild else {
            return .init(canDownload: false, canLoad: false, canUnload: false)
        }

        // Runtime-level serialisation: if anything is loading or unloading
        // anywhere, no row may start a new load.
        let runtimeBusy: Bool = {
            switch runtimeState {
            case .loading, .unloading: return true
            default:                   return false
            }
        }()

        // Download enablement: only when the file is absent AND no transport
        // is already in-flight for this model. Failure rows present "Retry"
        // through the same affordance, so we keep that path enabled.
        //
        // **No hard hardware gate.** Heavy / iPad-only entries (Gemma 3n,
        // Llama 8B etc.) remain downloadable on iPhone — the user opts in
        // via the confirm sheet that explicitly warns the load / generation
        // may fail under memory pressure. The catalog row UI adds a soft
        // "Experimentální na iPhonu" badge so the risk is visible upfront.
        // The only true block is `isUsableInThisBuild`, which means the
        // backend is missing from the build (different concern, handled
        // separately above).
        let canDownload: Bool = {
            switch status {
            case .notInstalled, .downloadFailed:
                return !DownloadManager.shared.isActive(model.id)
            default:
                return false
            }
        }()

        // Load enablement: installed, no other operation in flight, and not
        // already the active model. `.loadFailed` is allowed so the Retry
        // button can route through onLoad.
        let canLoad: Bool = {
            switch status {
            case .installed, .loadFailed:
                return !runtimeBusy && activeModelID != model.id
            default:
                return false
            }
        }()

        // Unload enablement: only when THIS model is the active runtime
        // model and the state machine is stable (no concurrent load /
        // unload). The runtime would otherwise queue and serialise, but
        // a disabled button is clearer to the user than a queued one.
        let canUnload: Bool = {
            guard activeModelID == model.id else { return false }
            switch runtimeState {
            case .ready: return true
            default:     return false
            }
        }()

        return .init(canDownload: canDownload, canLoad: canLoad, canUnload: canUnload)
    }

    private func computeStatus(
        model:           LocalModel,
        activeModelID:   String?,
        runtimeState:    RuntimeManager.State,
        unloadingID:     String?,
        activeDownloads: [String: ModelDownloadService.DownloadState]
    ) -> ModelBrowserStatus {

        // 1. Runtime active — highest priority.
        if activeModelID == model.id { return .loaded }

        // 2. Runtime loading this specific model.
        if case .loading(let id) = runtimeState, id == model.id { return .loading }

        // 3. Runtime unloading this specific model.
        if let uid = unloadingID, uid == model.id { return .unloading }

        // 4. Runtime load failed for this model.
        if case .failed(let failedID, let reason) = runtimeState, failedID == model.id {
            return .loadFailed(reason: reason)
        }

        // 5. Derive from catalog install state.
        switch model.installState {

        case .notInstalled:
            return .notInstalled

        case .downloading(let progress):
            // Reconnecting: transport is alive (survived OS kill) but no
            // in-process DownloadState yet — show spinner, not an empty bar.
            if DownloadManager.shared.isActive(model.id) && activeDownloads[model.id] == nil {
                return .reconnecting
            }
            let phase = activeDownloads[model.id]?.phase ?? .preparing
            return .downloading(progress: progress, phase: phase)

        case .installed:
            return .installed

        case .loaded:
            // Catalog says loaded but runtime doesn't agree → treat as installed.
            return .installed

        case .failed(let reason):
            return .downloadFailed(reason: reason)
        }
    }
}
