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

    // MARK: - Download phase

    /// Granular phase within an active download, surfaced in the UI so the
    /// user always knows what is happening.
    enum DownloadPhase: Equatable {
        case preparing
        case downloading
        case validating
        case installing

        var label: String {
            switch self {
            case .preparing:   return "Preparing…"
            case .downloading: return "Downloading"
            case .validating:  return "Validating…"
            case .installing:  return "Installing…"
            }
        }
    }

    struct DownloadState: Equatable {
        var modelID: String
        var progress: Double
        var isCancelled: Bool
        var phase: DownloadPhase = .preparing
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
            forKey: resumeDataKey(for: modelID)
        ) != nil
    }

    func start(_ model: LocalModel) {
        guard active[model.id] == nil else { return }
        active[model.id] = DownloadState(modelID: model.id, progress: 0, isCancelled: false, phase: .preparing)
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
        // Cancel the URLSession task; coordinator will attempt to save resume data
        // asynchronously. We intentionally do NOT clear resume data here so the
        // user can resume. Call clearResumeData() only when starting fresh.
        BackgroundDownloadCoordinator.shared.cancelDownload(modelID: modelID)
        #endif
        catalog.setInstallState(.notInstalled, for: modelID)
    }

    /// Deletes a model's file from disk, unloads it from the runtime if active,
    /// and removes user-added models from the catalog entirely.
    ///
    /// - Parameter modelID: The ID of the model to delete.
    /// - Parameter runtime: The runtime manager used to unload an active model.
    func deleteModel(_ modelID: String, runtime: RuntimeManager) async {
        // Can't delete while a download is in progress — cancel it first.
        if active[modelID] != nil {
            cancel(modelID)
        }

        // Unload from runtime if this is the currently active model.
        if runtime.activeModel?.id == modelID {
            await runtime.unload()
        }

        // Remove file from disk.
        try? await localModels.remove(modelID)

        // Update catalog: user-added models are removed entirely; curated models
        // just revert to .notInstalled so the user can re-download them.
        if catalog.model(withID: modelID)?.isUserAdded == true {
            catalog.removeUserModel(id: modelID)
        } else {
            catalog.setInstallState(.notInstalled, for: modelID)
        }
    }

    /// Creates a user-defined model from a direct URL and starts downloading it.
    ///
    /// The model is added to the catalog with `isUserAdded = true` and persisted
    /// in `user-models.json`. The download uses the same pipeline as curated models.
    ///
    /// - Parameters:
    ///   - name: Display name chosen by the user (used as-is).
    ///   - url: Direct HTTPS download URL for the .gguf file.
    ///   - contextLength: Context window size; defaults to 4096 if unknown.
    func importFromURL(name: String, url: URL, contextLength: Int = 4096) {
        // Build a stable ID from the name: lowercase, spaces → hyphens, alphanum only.
        let sanitized = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        let modelID = "user-\(sanitized)-\(Int(Date().timeIntervalSince1970) % 100_000)"

        let model = LocalModel(
            id: modelID,
            displayName: name,
            family: "Custom",
            parameterCount: "?",
            quantization: "?",
            sizeBytes: 0,
            contextLength: contextLength,
            downloadURL: url,
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Unknown",
            isUserAdded: true
        )

        catalog.addUserModel(model)
        start(model)
    }

    /// Re-scans the models directory and reconciles catalog install states.
    /// Safe to call from pull-to-refresh; delegates to ModelCatalogService.
    func reconcileInstallStates() async {
        await catalog.reconcileInstallStates(localModels: localModels)
    }

    /// Cancels all active downloads, deletes every `.gguf` file on disk,
    /// and resets every catalog entry to `.notInstalled`.
    func resetAllModels() async {
        for modelID in Array(active.keys) {
            cancel(modelID)
        }
        try? await localModels.removeAll()
        for model in catalog.models {
            catalog.setInstallState(.notInstalled, for: model.id)
        }
    }

    // MARK: - Real download (HOMEHUB_REAL_RUNTIME)

#if HOMEHUB_REAL_RUNTIME

    enum DownloadError: LocalizedError {
        case checksumMismatch(expected: String, actual: String)
        case fileMoveFailed(String)
        case fileMissingAfterDownload

        var errorDescription: String? {
            switch self {
            case .checksumMismatch(let expected, let actual):
                return "SHA-256 mismatch: expected \(expected.prefix(12))…, got \(actual.prefix(12))…"
            case .fileMoveFailed(let msg):
                return "Downloaded file could not be moved into Models directory: \(msg)"
            case .fileMissingAfterDownload:
                return "Model file is missing after download — the system may have deleted the temp file."
            }
        }
    }

    private func setupCoordinatorCallbacks() {
        let coordinator = BackgroundDownloadCoordinator.shared
        coordinator.onProgress = { [weak self] id, fraction in
            guard let self else { return }
            self.active[id]?.progress = fraction
            self.active[id]?.phase = .downloading
            self.catalog.setInstallState(.downloading(progress: fraction), for: id)
        }
        coordinator.onCompleted = { [weak self] id, tempURL in
            guard let self else { return }
            Task { await self.finalizeDownload(modelID: id, tempURL: tempURL) }
        }
        coordinator.onFailed = { [weak self] id, error, resumeData in
            guard let self else { return }
            self.handleDownloadError(modelID: id, error: error, resumeData: resumeData)
        }
    }

    private func realDownload(model: LocalModel) async {
        let modelID = model.id
        let localURL = await localModels.localURL(for: modelID)

        try? FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        active[modelID]?.phase = .downloading

        let coordinator = BackgroundDownloadCoordinator.shared
        if let resumeData = loadResumeData(for: modelID) {
            // Clear resume data now; a fresh cancel will store new resume data.
            clearResumeData(for: modelID)
            coordinator.startDownload(modelID: modelID, resumeData: resumeData)
        } else {
            coordinator.startDownload(modelID: modelID, url: model.downloadURL)
        }
        // Download now runs independently in the background session.
    }

    @MainActor
    private func finalizeDownload(modelID: String, tempURL: URL) async {
        // Guard: if the download was cancelled between completion callback and here,
        // just clean up the temp file and do nothing.
        guard active[modelID] != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            catalog.setInstallState(.failed(reason: DownloadError.fileMissingAfterDownload.errorDescription!), for: modelID)
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }

        let localURL = await localModels.localURL(for: modelID)
        let model = catalog.models.first { $0.id == modelID }

        do {
            if let expectedHash = model?.sha256 {
                active[modelID]?.phase = .validating
                catalog.setInstallState(.downloading(progress: 1.0), for: modelID)
                let actualHash = try await Task.detached(priority: .userInitiated) {
                    try ModelDownloadService.sha256Hash(of: tempURL)
                }.value
                guard actualHash.lowercased() == expectedHash.lowercased() else {
                    throw DownloadError.checksumMismatch(expected: expectedHash, actual: actualHash)
                }
            }

            active[modelID]?.phase = .installing
            catalog.setInstallState(.downloading(progress: 1.0), for: modelID)

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
                    ? "Download paused — no network. Tap Retry to resume when connected."
                    : "No internet connection. Try again when connected."
            case .cancelled:
                // User-initiated cancel; state already reset by cancel().
                active[modelID] = nil
                tasks[modelID] = nil
                return
            default:
                reason = "Network error: \(urlError.localizedDescription)"
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

#else

    // Non-real-runtime stub for resumeDataKey used by hasResumeData()
    private func resumeDataKey(for modelID: String) -> String {
        "com.homehub.app.resumeData.\(modelID)"
    }

#endif

    // MARK: - Simulated download (development builds)

    private func simulateDownload(model: LocalModel) async {
        active[model.id]?.phase = .downloading
        var progress: Double = 0
        while progress < 1.0 {
            if Task.isCancelled { return }
            if active[model.id]?.isCancelled == true { return }
            try? await Task.sleep(nanoseconds: 180_000_000)
            progress = min(progress + 0.04, 1.0)
            active[model.id]?.progress = progress
            catalog.setInstallState(.downloading(progress: progress), for: model.id)
        }

        active[model.id]?.phase = .installing
        let localURL = await localModels.localURL(for: model.id)

        // Create a stub file so the UI flow works in dev/simulator.
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
