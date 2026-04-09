import Foundation
import SwiftUI

/// Handles downloading a `LocalModel` to disk and keeping the
/// catalog's `installState` in sync.
///
/// v1 Simplification: uses a simulated progress loop so the UI is
/// fully wired end-to-end without a real network fetch. Future
/// implementation: a real `URLSessionDownloadDelegate`-driven
/// download with background session support, resume data, SHA-256
/// verification, and Wi-Fi-only gating.
@MainActor
final class ModelDownloadService: ObservableObject {
    struct DownloadState: Equatable {
        var modelID: String
        var progress: Double
        var isCancelled: Bool
    }

    @Published private(set) var active: [String: DownloadState] = [:]

    private let localModels: LocalModelService
    private let catalog: ModelCatalogService
    private var tasks: [String: Task<Void, Never>] = [:]

    init(localModels: LocalModelService, catalog: ModelCatalogService) {
        self.localModels = localModels
        self.catalog = catalog
    }

    func isDownloading(_ modelID: String) -> Bool {
        active[modelID] != nil
    }

    func start(_ model: LocalModel) {
        guard active[model.id] == nil else { return }
        active[model.id] = DownloadState(modelID: model.id, progress: 0, isCancelled: false)
        catalog.setInstallState(.downloading(progress: 0), for: model.id)

        tasks[model.id] = Task { [weak self] in
            await self?.simulateDownload(model: model)
        }
    }

    func cancel(_ modelID: String) {
        active[modelID]?.isCancelled = true
        tasks[modelID]?.cancel()
        tasks[modelID] = nil
        active[modelID] = nil
        catalog.setInstallState(.notInstalled, for: modelID)
    }

    private func simulateDownload(model: LocalModel) async {
        var progress: Double = 0
        while progress < 1.0 {
            if Task.isCancelled { return }
            if active[model.id]?.isCancelled == true { return }
            try? await Task.sleep(nanoseconds: 180_000_000)
            progress = min(progress + 0.04, 1.0)
            active[model.id]?.progress = progress
            catalog.setInstallState(.downloading(progress: progress), for: model.id)
        }

        let localURL = await localModels.localURL(for: model.id)
        catalog.setInstallState(.installed(localURL: localURL), for: model.id)
        active[model.id] = nil
        tasks[model.id] = nil
    }
}
