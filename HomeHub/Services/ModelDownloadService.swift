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
        // User chose to cancel — wipe resume data so next attempt starts fresh.
        clearResumeData(for: modelID)
        #endif
        catalog.setInstallState(.notInstalled, for: modelID)
    }

    // MARK: - Real download (HOMEHUB_REAL_RUNTIME)

#if HOMEHUB_REAL_RUNTIME

    enum DownloadError: LocalizedError {
        case checksumMismatch(expected: String, actual: String)
        case invalidResponse(statusCode: Int)
        case fileMoveFailed(String)

        var errorDescription: String? {
            switch self {
            case .checksumMismatch(let expected, let actual):
                return "SHA-256 mismatch: expected \(expected.prefix(12))…, got \(actual.prefix(12))…"
            case .invalidResponse(let code):
                return "Server returned HTTP \(code)"
            case .fileMoveFailed(let msg):
                return "Failed to move downloaded file: \(msg)"
            }
        }
    }

    private func realDownload(model: LocalModel) async {
        let modelID = model.id

        do {
            let localURL = await localModels.localURL(for: modelID)

            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let progressDelegate = DownloadProgressDelegate { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.active[modelID] != nil else { return }
                    self.active[modelID]?.progress = fraction
                    self.catalog.setInstallState(.downloading(progress: fraction), for: modelID)
                }
            }

            // Per-download session: 2-hour resource timeout for large GGUF files.
            // Using a dedicated session (not URLSession.shared) keeps configuration isolated
            // and ensures finishTasksAndInvalidate() cleans up cleanly on early exit.
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 7_200    // 2 h — large models on slow connections
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }

            let tempURL: URL
            let response: URLResponse

            // Resume an interrupted download when the server supports range requests.
            if let resumeData = loadResumeData(for: modelID) {
                (tempURL, response) = try await session.download(
                    resumingWith: resumeData,
                    delegate: progressDelegate
                )
                clearResumeData(for: modelID)
            } else {
                (tempURL, response) = try await session.download(
                    from: model.downloadURL,
                    delegate: progressDelegate
                )
            }

            guard !Task.isCancelled, active[modelID]?.isCancelled != true else { return }

            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw DownloadError.invalidResponse(statusCode: http.statusCode)
            }

            if let expectedHash = model.sha256 {
                let actualHash = try sha256Hash(of: tempURL)
                guard actualHash.lowercased() == expectedHash.lowercased() else {
                    throw DownloadError.checksumMismatch(
                        expected: expectedHash,
                        actual: actualHash
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
            active[modelID] = nil
            tasks[modelID] = nil

        } catch is CancellationError {
            // User-initiated cancel — resume data already cleared by cancel().
        } catch let urlError as URLError {
            // Persist resume data so we can continue where we left off on retry.
            if let data = urlError.downloadTaskResumeData {
                saveResumeData(data, for: modelID)
            }
            let reason: String
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                reason = urlError.downloadTaskResumeData != nil
                    ? "Download paused. Reconnect to continue."
                    : "No internet connection. Try again when connected."
            default:
                reason = urlError.localizedDescription
            }
            catalog.setInstallState(.failed(reason: reason), for: modelID)
            active[modelID] = nil
            tasks[modelID] = nil
        } catch {
            catalog.setInstallState(.failed(reason: error.localizedDescription), for: modelID)
            active[modelID] = nil
            tasks[modelID] = nil
        }
    }

    // MARK: - Resume Data

    /// Returns resume data saved from a previous interrupted download, if any.
    private func loadResumeData(for modelID: String) -> Data? {
        UserDefaults.standard.data(forKey: resumeDataKey(for: modelID))
    }

    /// Persists resume data to UserDefaults so interrupted downloads can continue
    /// after an app restart or network interruption.
    private func saveResumeData(_ data: Data, for modelID: String) {
        UserDefaults.standard.set(data, forKey: resumeDataKey(for: modelID))
    }

    /// Removes stored resume data. Called on user-initiated cancel or successful
    /// download completion.
    func clearResumeData(for modelID: String) {
        UserDefaults.standard.removeObject(forKey: resumeDataKey(for: modelID))
    }

    private func resumeDataKey(for modelID: String) -> String {
        "com.homehub.app.resumeData.\(modelID)"
    }

    /// Computes SHA-256 hash of a file using streaming 1 MB reads.
    private func sha256Hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1_024 * 1_024  // 1 MB

        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
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

// MARK: - URLSession Download Progress Delegate

#if HOMEHUB_REAL_RUNTIME

/// Lightweight delegate that forwards download progress to a closure.
/// Each `ModelDownloadService.start()` creates its own delegate instance
/// so progress is tracked per-download.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(fraction, 1.0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled by the async URLSession.download(from:delegate:) return value
    }
}

#endif
