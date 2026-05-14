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

    // Services – assigned once by connect().
    private weak var catalog:   ModelCatalogService?
    private weak var downloads: ModelDownloadService?
    private weak var runtime:   RuntimeManager?

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
        runtime:   RuntimeManager
    ) {
        guard !isConnected else { return }
        isConnected = true

        self.catalog   = catalog
        self.downloads = downloads
        self.runtime   = runtime

        // Synchronous initial pass — sections is populated before the next render.
        recompute()

        // Re-compute whenever any of the three sources publishes a change.
        Publishers.Merge3(
            catalog.objectWillChange  .map { _ in () }.eraseToAnyPublisher(),
            downloads.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            runtime.objectWillChange  .map { _ in () }.eraseToAnyPublisher()
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

        // During an explicit unload, `activeModel` is still set while
        // state == .unloading.  During a load-that-first-unloads, `activeModel`
        // is cleared before state becomes .unloading, so unloadingID is nil.
        let unloadingID: String?
        if case .unloading = runtimeState { unloadingID = runtime.activeModel?.id }
        else                              { unloadingID = nil }

        let newSections = buildSections(
            models:         catalog.models,
            activeModelID:  activeModelID,
            runtimeState:   runtimeState,
            unloadingID:    unloadingID,
            mlxProgress:    mlxProgress,
            activeDownloads: activeDownloads,
            downloads:      downloads
        )

        // Avoid spurious SwiftUI diffing passes when nothing actually changed.
        if newSections != sections { sections = newSections }
    }

    private func buildSections(
        models:          [LocalModel],
        activeModelID:   String?,
        runtimeState:    RuntimeManager.State,
        unloadingID:     String?,
        mlxProgress:     MLXLoadProgress?,
        activeDownloads: [String: ModelDownloadService.DownloadState],
        downloads:       ModelDownloadService
    ) -> [ModelBrowserSection] {
        var onDevice:  [ModelBrowserItem] = []
        var available: [ModelBrowserItem] = []

        for model in models {
            let status = computeStatus(
                model:           model,
                activeModelID:   activeModelID,
                runtimeState:    runtimeState,
                unloadingID:     unloadingID,
                activeDownloads: activeDownloads
            )
            let item = ModelBrowserItem(
                model:           model,
                status:          status,
                hasResumeData:   downloads.hasResumeData(for: model.id),
                mlxLoadProgress: mlxProgress?.modelID == model.id ? mlxProgress : nil
            )
            if case .notInstalled = status { available.append(item) }
            else                           { onDevice.append(item) }
        }

        var result: [ModelBrowserSection] = []
        if !onDevice.isEmpty  { result.append(.init(kind: .onDevice,  items: onDevice)) }
        if !available.isEmpty { result.append(.init(kind: .available, items: available)) }
        return result
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
