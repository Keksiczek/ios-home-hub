import Foundation
import SwiftUI
import os
#if HOMEHUB_REAL_RUNTIME
import CryptoKit
#endif

/// Handles downloading a `LocalModel` to disk and keeping the
/// catalog's `installState` in sync.
///
/// ## Pipeline overview (unified for curated catalog + `Add from URL`)
///
/// Both entry points funnel through `start(_:)` → either `realDownload()`
/// (HOMEHUB_REAL_RUNTIME) or `simulateDownload()`. Both branches run the
/// same post-download steps:
///
/// 1. Write bytes into `LocalModelService.localURL(for:)` (Application
///    Support / Models / `<id>.gguf`), using an atomic move from a temp
///    file. The runtime reads from this exact same path.
/// 2. Validate the file (GGUF magic header check, optional SHA-256).
/// 3. Flip `ModelCatalogService.installState` to `.installed(localURL:)`.
/// 4. Invoke `onModelInstalled` so `AppContainer` can auto-activate the
///    model the first time the user has no active selection.
///
/// ## Build modes
/// - **`HOMEHUB_REAL_RUNTIME`**: Real `URLSession` downloads with progress
///   tracking via delegate, SHA-256 verification, and cancel support.
/// - **Default (dev)**: Simulated progress loop so the UI is fully wired
///   end-to-end without a real network fetch. Writes a file with a valid
///   GGUF magic header + padding so it survives
///   `LocalModelService.isStubOrInvalidGGUF()` reconciliation.
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

    /// Called on the main actor after a model successfully transitions to
    /// `.installed`. `AppContainer` wires this up to auto-activate the first
    /// installed model when the user hasn't picked one yet — otherwise a
    /// fresh download could never flip `runtime.activeModel != nil` without
    /// the user finding and tapping "Load" manually.
    var onModelInstalled: ((LocalModel) async -> Void)?

    private let localModels: LocalModelService
    private let catalog: ModelCatalogService
    private var tasks: [String: Task<Void, Never>] = [:]

    private let log = Logger(subsystem: "com.homehub.app", category: "ModelDownloadService")

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
        log.info("Starting download for model '\(model.id, privacy: .public)' from \(model.downloadURL.absoluteString, privacy: .public)")

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
        log.info("Cancelled download for '\(modelID, privacy: .public)'")
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
        do {
            try await localModels.remove(modelID)
        } catch {
            log.error("Failed to remove model file for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }

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
    /// in `user-models.json`. The download uses the **same pipeline** as curated
    /// models — `start(_:)` → URLSession/simulate → GGUF validation → install.
    ///
    /// - Parameters:
    ///   - name: Display name chosen by the user (must be non-empty).
    ///   - url: Direct HTTPS/HTTP download URL for the .gguf file.
    ///   - contextLength: Context window size; defaults to 4096 if unknown.
    /// - Throws: `URLImportError.invalidName` / `.invalidURL` when inputs are rejected.
    func importFromURL(name: String, url: URL, contextLength: Int = 4096) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw URLImportError.invalidName
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw URLImportError.invalidURL
        }

        // Build a stable ID from the name: lowercase, spaces → hyphens, alphanum only.
        let sanitized = trimmedName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        let safeSanitized = sanitized.isEmpty ? "custom" : sanitized
        let modelID = "user-\(safeSanitized)-\(Int(Date().timeIntervalSince1970) % 100_000)"

        let model = LocalModel(
            id: modelID,
            displayName: trimmedName,
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

    enum URLImportError: LocalizedError {
        case invalidName
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Model name is required."
            case .invalidURL:  return "URL must start with http:// or https://."
            }
        }
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

    // MARK: - Shared post-download finalization

    /// Shared install step used by both real and simulated paths.
    /// Moves `tempURL` into `localURL`, validates the resulting file,
    /// updates catalog state, and fires `onModelInstalled`.
    private func completeInstall(
        modelID: String,
        tempURL: URL,
        localURL: URL
    ) async {
        // If the download was cancelled between callback and here, swallow the
        // temp file and bail. Callers have already reset catalog state.
        guard active[modelID] != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        active[modelID]?.phase = .installing

        do {
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: tempURL, to: localURL)
        } catch {
            log.error("moveItem failed for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempURL)
            catalog.setInstallState(
                .failed(reason: "File move failed: \(error.localizedDescription)"),
                for: modelID
            )
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }

        // Validate the resulting file is a plausible GGUF before declaring success.
        // This catches e.g. HuggingFace gated-model HTML error pages being saved
        // with a .gguf extension by `URLSession.downloadTask`.
        if !Self.isValidGGUFHeader(at: localURL) {
            log.error("GGUF magic check failed for '\(modelID, privacy: .public)' at \(localURL.path, privacy: .public)")
            try? FileManager.default.removeItem(at: localURL)
            catalog.setInstallState(
                .failed(reason: "Downloaded file is not a valid GGUF model. The URL may be gated, require authentication, or point to an error page."),
                for: modelID
            )
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }

        catalog.setInstallState(.installed(localURL: localURL), for: modelID)
        active[modelID] = nil
        tasks[modelID] = nil
        log.info("Model '\(modelID, privacy: .public)' installed at \(localURL.path, privacy: .public)")

        // Hook out to AppContainer for auto-activation of the first installed model.
        if let model = catalog.model(withID: modelID) {
            await onModelInstalled?(model)
        }
    }

    /// Reads the first 4 bytes of `url` and checks for the `GGUF` magic.
    /// Returns `false` for missing files, unreadable files, or non-GGUF files.
    static func isValidGGUFHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        return magic == Data([0x47, 0x47, 0x55, 0x46])
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
        // Now that callbacks are wired, reconnect to any in-flight background
        // session from a previous app run so queued events are delivered here
        // (rather than being dropped before we were ready to handle them).
        coordinator.reconnect()
    }

    private func realDownload(model: LocalModel) async {
        let modelID = model.id
        let localURL = await localModels.localURL(for: modelID)

        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            log.error("createDirectory failed for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }

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
            log.error("Temp file missing after download for '\(modelID, privacy: .public)'")
            catalog.setInstallState(.failed(reason: DownloadError.fileMissingAfterDownload.errorDescription!), for: modelID)
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }

        let localURL = await localModels.localURL(for: modelID)
        let model = catalog.models.first { $0.id == modelID }

        // Optional SHA-256 check — only runs when the curated catalog provides
        // a hash. User-added models never have one.
        if let expectedHash = model?.sha256 {
            active[modelID]?.phase = .validating
            catalog.setInstallState(.downloading(progress: 1.0), for: modelID)
            do {
                let actualHash = try await Task.detached(priority: .userInitiated) {
                    try ModelDownloadService.sha256Hash(of: tempURL)
                }.value
                guard actualHash.lowercased() == expectedHash.lowercased() else {
                    let err = DownloadError.checksumMismatch(expected: expectedHash, actual: actualHash)
                    log.error("SHA-256 mismatch for '\(modelID, privacy: .public)'")
                    try? FileManager.default.removeItem(at: tempURL)
                    catalog.setInstallState(.failed(reason: err.errorDescription ?? "Checksum mismatch"), for: modelID)
                    active[modelID] = nil
                    tasks[modelID] = nil
                    return
                }
            } catch {
                log.error("SHA-256 hashing failed for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: tempURL)
                catalog.setInstallState(.failed(reason: error.localizedDescription), for: modelID)
                active[modelID] = nil
                tasks[modelID] = nil
                return
            }
        }

        catalog.setInstallState(.downloading(progress: 1.0), for: modelID)
        await completeInstall(modelID: modelID, tempURL: tempURL, localURL: localURL)
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
        log.error("Download failed for '\(modelID, privacy: .public)': \(reason, privacy: .public)")
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

        let localURL = await localModels.localURL(for: model.id)

        // Write a stub file that passes both the size and GGUF-magic guards
        // in `LocalModelService.isStubOrInvalidGGUF` so reconciliation on the
        // next app launch does NOT erase the model. 1 MiB of padding is well
        // above the 1 MB threshold while staying cheap on disk.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-\(UUID().uuidString).gguf")
        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var payload = Data([0x47, 0x47, 0x55, 0x46])   // "GGUF" magic
            payload.append(Data(count: 1_048_576))          // 1 MiB zero-pad
            try payload.write(to: tempURL, options: .atomic)
        } catch {
            log.error("Simulated stub write failed for '\(model.id, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            catalog.setInstallState(
                .failed(reason: "Could not prepare simulated model file: \(error.localizedDescription)"),
                for: model.id
            )
            active[model.id] = nil
            tasks[model.id] = nil
            return
        }

        await completeInstall(modelID: model.id, tempURL: tempURL, localURL: localURL)
    }
}
