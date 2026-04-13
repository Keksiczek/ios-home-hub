import Foundation
import SwiftUI
#if HOMEHUB_REAL_RUNTIME
import CryptoKit
#endif

/// Handles downloading a `LocalModel` to disk and keeping the
/// catalog's `installState` in sync.
///
/// ## Build modes
/// - **`HOMEHUB_REAL_RUNTIME`**: Real `URLSession` downloads with progress
///   tracking via delegate, SHA-256 verification, and cancel support.
/// - **Default (dev)**: Simulated progress loop so the UI is fully wired
///   end-to-end without a real network fetch.
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
        #if HOMEHUB_REAL_RUNTIME
        setupCoordinatorCallbacks()
        #endif
    }

    func isDownloading(_ modelID: String) -> Bool {
        active[modelID] != nil
    }

    /// Returns `true` when a previous download was interrupted and resume
    /// data is available. The UI shows a "Paused" badge in this state.
    func hasResumeData(for modelID: String) -> Bool {
        UserDefaults.standard.data(
            forKey: "com.homehub.app.resumeData.\(modelID)"
        ) != nil
    }

    func start(_ model: LocalModel) {
        guard active[model.id] == nil else { return }
        active[model.id] = DownloadState(modelID: model.id, progress: 0, isCancelled: false)
        catalog.setInstallState(.downloading(progress: 0), for: model.id)

        tasks[model.id] = Task { [weak self] in
            #if HOMEHUB_REAL_RUNTIME
            await self?.realDownload(model: model)
            #else
            await self?.simulateDownload(model: model)
            #endif
        }
    }

    func cancel(_ modelID: String) {
        active[modelID]?.isCancelled = true
        tasks[modelID]?.cancel()
        tasks[modelID] = nil
        active[modelID] = nil
        #if HOMEHUB_REAL_RUNTIME
        // Ask the coordinator to cancel the URLSession task and store
        // resume data; then wipe it so the next tap starts fresh.
        BackgroundDownloadCoordinator.shared.cancelDownload(modelID: modelID)
        clearResumeData(for: modelID)
        #endif
        catalog.setInstallState(.notInstalled, for: modelID)
    }

    /// Cancels all active downloads, deletes every `.gguf` file on disk,
    /// and resets every catalog entry to `.notInstalled`.
    ///
    /// Use this to purge dev-mode stub files created by the simulated
    /// downloader, or to start fresh after a bad real download. The caller
    /// should also call `RuntimeManager.clearState()` if a model is loaded,
    /// because this method does not touch the runtime.
    func resetAllModels() async {
        // 1. Cancel every in-flight download (real or simulated).
        for modelID in Array(active.keys) {
            cancel(modelID)
        }
        // 2. Delete all .gguf files from disk.
        try? await localModels.removeAll()
        // 3. Reset every catalog entry so the UI shows "Not installed".
        for model in catalog.models {
            catalog.setInstallState(.notInstalled, for: model.id)
        }
    }

    // MARK: - Real download (HOMEHUB_REAL_RUNTIME)

#if HOMEHUB_REAL_RUNTIME

    enum DownloadError: LocalizedError {
        case checksumMismatch(expected: String, actual: String)
        case fileMoveFailed(String)

        var errorDescription: String? {
            switch self {
            case .checksumMismatch(let expected, let actual):
                return "SHA-256 mismatch: expected \(expected.prefix(12))…, got \(actual.prefix(12))…"
            case .fileMoveFailed(let msg):
                return "Failed to move downloaded file: \(msg)"
            }
        }
    }

    /// Wire coordinator callbacks once at init. The coordinator routes
    /// events back here by model ID so multiple downloads work correctly.
    private func setupCoordinatorCallbacks() {
        let coordinator = BackgroundDownloadCoordinator.shared
        coordinator.onProgress = { [weak self] id, fraction in
            guard let self else { return }
            self.active[id]?.progress = fraction
            self.catalog.setInstallState(.downloading(progress: fraction), for: id)
        }
        coordinator.onCompleted = { [weak self] id, tempURL in
            guard let self else { return }
            // Checksum + file move may be slow — keep off the calling Task.
            Task { await self.finalizeDownload(modelID: id, tempURL: tempURL) }
        }
        coordinator.onFailed = { [weak self] id, error, resumeData in
            guard let self else { return }
            self.handleDownloadError(modelID: id, error: error, resumeData: resumeData)
        }
    }

    /// Kick off a background URLSession download. Returns immediately; all
    /// progress/completion callbacks arrive via `setupCoordinatorCallbacks`.
    private func realDownload(model: LocalModel) async {
        let modelID = model.id
        let localURL = await localModels.localURL(for: modelID)

        // Ensure the destination directory exists before the download lands.
        try? FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let coordinator = BackgroundDownloadCoordinator.shared
        if let resumeData = loadResumeData(for: modelID) {
            clearResumeData(for: modelID)
            coordinator.startDownload(modelID: modelID, resumeData: resumeData)
        } else {
            coordinator.startDownload(modelID: modelID, url: model.downloadURL)
        }
        // Download now runs independently in the background session.
        // This Task exits immediately; state is updated via coordinator callbacks.
    }

    /// Validate checksum (off the main thread) and move the file to its
    /// final location. Called on @MainActor via the coordinator callback.
    @MainActor
    private func finalizeDownload(modelID: String, tempURL: URL) async {
        let localURL = await localModels.localURL(for: modelID)

        // Find the corresponding model for SHA-256 validation.
        let model = catalog.models.first { $0.id == modelID }

        do {
            if let expectedHash = model?.sha256 {
                // SHA-256 of a 7 GB file is slow — detach from MainActor.
                let actualHash = try await Task.detached(priority: .userInitiated) {
                    try ModelDownloadService.sha256Hash(of: tempURL)
                }.value
                guard actualHash.lowercased() == expectedHash.lowercased() else {
                    throw DownloadError.checksumMismatch(
                        expected: expectedHash, actual: actualHash
                    )
                }
            }

            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            do {
                try FileManager.default.moveItem(at: tempURL, to: localURL)
            } catch {
                throw DownloadError.fileMoveFailed(error.localizedDescription)
            }

            catalog.setInstallState(.installed(localURL: localURL), for: modelID)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            catalog.setInstallState(.failed(reason: error.localizedDescription), for: modelID)
        }
        active[modelID] = nil
        tasks[modelID] = nil
    }

    @MainActor
    private func handleDownloadError(modelID: String, error: Error, resumeData: Data?) {
        if let data = resumeData {
            saveResumeData(data, for: modelID)
        }
        let reason: String
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                reason = resumeData != nil
                    ? "Download paused. Reconnect to continue."
                    : "No internet connection. Try again when connected."
            default:
                reason = urlError.localizedDescription
            }
        } else {
            reason = error.localizedDescription
        }
        catalog.setInstallState(.failed(reason: reason), for: modelID)
        active[modelID] = nil
        tasks[modelID] = nil
    }

    // MARK: - Resume Data

    private func loadResumeData(for modelID: String) -> Data? {
        UserDefaults.standard.data(forKey: resumeDataKey(for: modelID))
    }

    private func saveResumeData(_ data: Data, for modelID: String) {
        UserDefaults.standard.set(data, forKey: resumeDataKey(for: modelID))
    }

    func clearResumeData(for modelID: String) {
        UserDefaults.standard.removeObject(forKey: resumeDataKey(for: modelID))
    }

    private func resumeDataKey(for modelID: String) -> String {
        "com.homehub.app.resumeData.\(modelID)"
    }

    /// Computes SHA-256 of a file using 1 MB streaming reads.
    /// `nonisolated` so it can run on `Task.detached` without isolation issues.
    static func sha256Hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1_024 * 1_024
        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

#endif

    // MARK: - Simulated download (development builds)

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

        // Create a stub file at the expected path so
        // LocalModelService.isInstalled() returns true and the UI
        // flow is consistent.
        if !FileManager.default.fileExists(atPath: localURL.path) {
            try? FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(
                atPath: localURL.path,
                contents: Data("STUB_MODEL".utf8)
            )
        }

        catalog.setInstallState(.installed(localURL: localURL), for: model.id)
        active[model.id] = nil
        tasks[model.id] = nil
    }
}

