import Foundation
import os

/// Single public authority for all model download operations.
///
/// `DownloadManager` is the **only** type that calls the transport workers
/// directly. All external code (`ModelDownloadService`, `AppContainer`, tests)
/// routes through this type — never through the coordinators directly.
///
/// ## Responsibility table
///
/// | Type                            | Public / Internal | State owned                          | State observed only      |
/// |---------------------------------|-------------------|--------------------------------------|--------------------------|
/// | `DownloadManager`               | **Public**        | `activeModelIDs` (canonical set)     | —                        |
/// | `BackgroundDownloadCoordinator` | Internal          | `taskModelMap`, URLSession (GGUF)    | —                        |
/// | `MLXBackgroundDownloader`       | Internal          | `taskMap`, `jobMap`, URLSession (MLX)| —                        |
/// | `ModelDownloadService`          | Public facade     | `DownloadState`, catalog state       | `activeModelIDs`         |
///
/// ## Why `@MainActor final class` and not `actor`?
/// The transport workers and all their callbacks are already pinned to
/// `@MainActor`. An isolated `actor` would require crossing the actor boundary
/// on every call — adding `await` noise with no safety benefit. `@MainActor
/// final class` provides the same single-executor guarantee with synchronous
/// call sites.
@MainActor
final class DownloadManager {

    static let shared = DownloadManager()

    // MARK: - Internal workers (not public API)

    /// GGUF single-file background transport.
    let gguf = BackgroundDownloadCoordinator.shared
    /// MLX multi-file background transport.
    let mlx  = MLXBackgroundDownloader.shared

    private let log = Logger(subsystem: "com.homehub.app", category: "DownloadManager")

    // MARK: - Canonical download state

    /// Canonical set of model IDs whose **transport** is currently in-flight.
    ///
    /// This covers both GGUF and MLX paths and is the single source of truth
    /// for "is a background URLSession task running for this model?".
    /// Post-download work (SHA-256, file-move, catalog update) is tracked
    /// separately by `ModelDownloadService.active`.
    private(set) var activeModelIDs: Set<String> = []

    private init() {}

    // MARK: - GGUF transport

    /// Starts a fresh GGUF background download.
    func start(modelID: String, url: URL) {
        activeModelIDs.insert(modelID)
        log.info("DownloadManager: GGUF start '\(modelID, privacy: .public)' url=\(url.host ?? "?", privacy: .public)")
        gguf.startDownload(modelID: modelID, url: url)
    }

    /// Resumes a previously interrupted GGUF download from resume data.
    func resume(modelID: String, resumeData: Data) {
        activeModelIDs.insert(modelID)
        log.info("DownloadManager: GGUF resume '\(modelID, privacy: .public)' resumeData=\(resumeData.count) B")
        gguf.startDownload(modelID: modelID, resumeData: resumeData)
    }

    // MARK: - MLX transport

    /// Starts a MLX multi-file background download.
    func startMLX(modelID: String, repoId: String, cacheDir: URL, files: [HFFileEntry]) {
        activeModelIDs.insert(modelID)
        log.info("DownloadManager: MLX start '\(modelID, privacy: .public)' repo=\(repoId, privacy: .public) files=\(files.count)")
        mlx.startDownload(modelID: modelID, repoId: repoId, cacheDir: cacheDir, files: files)
    }

    // MARK: - Cancel

    /// Cancels any in-flight transport for `modelID` across both workers.
    /// Does not update the catalog — callers are responsible for that.
    func cancel(modelID: String) {
        activeModelIDs.remove(modelID)
        log.info("DownloadManager: cancel '\(modelID, privacy: .public)'")
        gguf.cancelDownload(modelID: modelID)
        mlx.cancelDownload(modelID: modelID)
    }

    // MARK: - Completion tracking

    /// Called by `ModelDownloadService` when a transport event (completion or
    /// failure) has been fully handled. Keeps `activeModelIDs` in sync with
    /// what the coordinators report.
    func markFinished(modelID: String) {
        activeModelIDs.remove(modelID)
    }

    // MARK: - Query

    /// Returns `true` when a URLSession download task is currently running for
    /// `modelID` in either transport worker.
    func isActive(_ modelID: String) -> Bool {
        activeModelIDs.contains(modelID)
    }

    // MARK: - Callback wiring + reconnect

    /// Wires `ModelDownloadService` callbacks into both transport workers and
    /// triggers reconnect on each. Must be called once — after the service has
    /// constructed its finalization closures — before any background events can
    /// arrive. Replaces the former `setupCoordinatorCallbacks()` scatter.
    func wireAndReconnect(
        ggufProgress:  @escaping @Sendable @MainActor (String, Double) -> Void,
        ggufCompleted: @escaping @Sendable @MainActor (String, URL) -> Void,
        ggufFailed:    @escaping @Sendable @MainActor (String, Error, Data?) -> Void,
        mlxProgress:   @escaping           @MainActor (String, Double) -> Void,
        mlxCompleted:  @escaping           @MainActor (String) -> Void,
        mlxFailed:     @escaping           @MainActor (String, Error) -> Void
    ) {
        gguf.onProgress  = ggufProgress
        gguf.onCompleted = ggufCompleted
        gguf.onFailed    = ggufFailed

        mlx.onProgress   = mlxProgress
        mlx.onCompleted  = mlxCompleted
        mlx.onFailed     = mlxFailed

        // Seed activeModelIDs from both coordinators' persisted manifests
        // BEFORE the async reconnect() calls fire. This ensures isActive() /
        // isDownloading() return true for background tasks that survived an
        // OS kill while the app was dead. The coordinators have already loaded
        // their manifests from disk in their init (restorePersistedState()).
        //
        // Correctness of the two-phase flow:
        //   1. Seed here — all manifest IDs enter activeModelIDs (live + orphaned).
        //   2. reconnect() fires getTasksWithCompletionHandler asynchronously.
        //   3. Orphan IDs (no live URLSession task) trigger onFailed →
        //      markFinished → remove from activeModelIDs.
        //   4. Live IDs remain in activeModelIDs until their task completes,
        //      at which point onCompleted/onFailed → markFinished removes them.
        let ggufIDs = gguf.manifestModelIDs
        let mlxIDs  = mlx.manifestModelIDs
        activeModelIDs.formUnion(ggufIDs)
        activeModelIDs.formUnion(mlxIDs)

        log.info("DownloadManager: callbacks wired; seeded \(ggufIDs.count + mlxIDs.count, privacy: .public) model IDs from manifests (GGUF=\(ggufIDs.count, privacy: .public) MLX=\(mlxIDs.count, privacy: .public)); reconnecting workers")
        gguf.reconnect()
        mlx.reconnect()
    }
}
