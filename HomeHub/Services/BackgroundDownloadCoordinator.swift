import Foundation
import os

/// Owns a single background `URLSession` for GGUF model downloads.
///
/// Downloads started through this coordinator continue in the background
/// when the app is suspended or killed by the OS. The system relaunches
/// the app (or delivers events to the existing process) when a download
/// completes, at which point `AppDelegate.handleEventsForBackgroundURLSession`
/// stores the system completion handler here.
///
/// ## State persistence
/// `taskModelMap` (taskIdentifier → modelID) is persisted to an atomic JSON
/// manifest in Application Support so that on relaunch after an OS-kill the
/// coordinator can call `getTasksWithCompletionHandler` and re-attach to any
/// tasks that `nsurlsessiond` kept alive in the background.
///
/// ## Thread-safety
/// Delegate callbacks from URLSession arrive on a private queue; `mapQueue`
/// serialises all access to shared mutable dictionaries. All user-facing
/// callbacks (`onProgress`, `onCompleted`, `onFailed`) are dispatched back to
/// `@MainActor` before being called.
final class BackgroundDownloadCoordinator: NSObject, BackgroundDownloadProgressing, @unchecked Sendable {

    static let shared = BackgroundDownloadCoordinator()
    static let sessionID = "com.homehub.app.modeldownload.v1"

    private let log = Logger(subsystem: "com.homehub.app", category: "BackgroundDownloadCoordinator")

    // MARK: - Session (lazy so the delegate adapter is fully initialised first)

    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.sessionID
        )
        config.isDiscretionary = false          // start ASAP, not at OS convenience
        config.sessionSendsLaunchEvents = true  // wake/relaunch app on completion
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - State (guarded by mapQueue)

    private let mapQueue = DispatchQueue(
        label: "com.homehub.coordinator.map", qos: .utility
    )
    /// Maps `URLSessionTask.taskIdentifier` → model ID.
    /// Persisted to Application Support so in-flight tasks can be reattached
    /// after the app is relaunched by nsurlsessiond.
    private var taskModelMap: [Int: String] = [:]
    /// Maps model ID → active download task (for synchronous cancel).
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    /// Stored by `AppDelegate` when the system wakes the app for this session.
    private var systemCompletionHandler: (() -> Void)?

    /// Throttling for progress updates to prevent UI thread saturation.
    private var lastProgressYield: [String: ContinuousClock.Instant] = [:]

    // MARK: - Callbacks (set once by ModelDownloadService; called on @MainActor)

    var onProgress: (@Sendable @MainActor (_ modelID: String, _ fraction: Double) -> Void)?
    var onCompleted: (@Sendable @MainActor (_ modelID: String, _ tempURL: URL) -> Void)?
    var onFailed: (@Sendable @MainActor (_ modelID: String, _ error: Error, _ resumeData: Data?) -> Void)?

    // MARK: - Manifest

    private struct GGUFManifest: Codable {
        static let currentVersion = 1
        var version: Int
        var tasks: [String: String]  // String(taskIdentifier) → modelID
    }

    private let store = ManifestStore<GGUFManifest>.appSupport(filename: "gguf-download-manifest.json")

    // One-time migration key from Wave 1 UserDefaults persistence.
    private static let legacyUDKey = "com.homehub.coordinator.taskMap.v1"

    // MARK: - Init

    private override init() {
        super.init()
        restorePersistedState()
        // NOTE: we do NOT touch `session` here. If we did, URLSession would
        // start delivering any in-flight background-session events before
        // `ModelDownloadService` has assigned `onProgress/onCompleted/onFailed`,
        // dropping those events on the floor. `reconnect()` is called explicitly
        // by `ModelDownloadService` after wiring callbacks.
    }

    // MARK: - Public API

    /// Model IDs currently tracked in the in-memory task map.
    ///
    /// Read by `DownloadManager.wireAndReconnect()` to seed `activeModelIDs`
    /// before the async `reconnect()` call fires — so `isActive()` /
    /// `isDownloading()` return `true` for any URLSession task that survived
    /// an OS kill while the app was dead. Orphan recovery in `reconnect()`
    /// will call `onFailed` for stale IDs and `markFinished` will prune them.
    var manifestModelIDs: Set<String> {
        mapQueue.sync { Set(taskModelMap.values) }
    }

    /// Forces session creation and reconnects to any in-flight background tasks
    /// from a previous app launch. Call this only after callbacks are wired.
    ///
    /// Also performs orphan recovery: any manifest entry whose task is no longer
    /// alive in `nsurlsessiond` is reported as failed and removed, preventing
    /// stale "downloading" UI state after an OS kill.
    func reconnect() {
        _ = session  // ensure lazy session is created
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            guard let self else { return }
            let existing = self.mapQueue.sync { self.taskModelMap }
            let liveIDs = Set(downloadTasks.map { $0.taskIdentifier })

            self.log.info("GGUF: reconnect — manifest=\(existing.count) live=\(liveIDs.count)")

            // Orphan recovery: manifest tasks whose URLSession task is gone.
            // These were abandoned by nsurlsessiond while the app was dead
            // (e.g. OS restarted the daemon, or the task exceeded its retry
            // budget). Completed tasks fire `didFinishDownloadingTo` as delegate
            // callbacks on reconnect — they are NOT orphans.
            var orphanModelIDs: Set<String> = []
            var orphanTIDs: [Int] = []
            for (tid, modelID) in existing where !liveIDs.contains(tid) {
                orphanModelIDs.insert(modelID)
                orphanTIDs.append(tid)
            }
            if !orphanTIDs.isEmpty {
                self.mapQueue.sync {
                    for tid in orphanTIDs { self.taskModelMap.removeValue(forKey: tid) }
                }
                self.persistState()
                let err = URLError(
                    .networkConnectionLost,
                    userInfo: [NSLocalizedDescriptionKey: "Download was interrupted while the app was stopped."]
                )
                for modelID in orphanModelIDs {
                    self.log.warning("GGUF: Orphaned download for '\(modelID, privacy: .public)' — task not in nsurlsessiond; notifying failed")
                    Task { @MainActor [weak self] in self?.onFailed?(modelID, err, nil) }
                }
            }

            // Unrecognised live tasks: present in URLSession but absent from the
            // manifest. This should not happen in normal operation (it would mean
            // the manifest was written before the task was created). Log and ignore.
            var resumed = 0
            for task in downloadTasks {
                guard let modelID = existing[task.taskIdentifier] else {
                    self.log.notice("GGUF: Unrecognised live task \(task.taskIdentifier) — no manifest entry, leaving to time out")
                    continue
                }
                self.log.info("GGUF: Resumed task \(task.taskIdentifier) for '\(modelID, privacy: .public)'")
                self.mapQueue.sync { self.activeTasks[modelID] = task }
                resumed += 1
            }
            self.log.info("GGUF: reconnect complete — orphans=\(orphanModelIDs.count) resumed=\(resumed)")
        }
    }

    func startDownload(modelID: String, url: URL) {
        log.info("GGUF: Starting download for '\(modelID, privacy: .public)'")
        let task = session.downloadTask(with: url)
        mapQueue.sync {
            taskModelMap[task.taskIdentifier] = modelID
            activeTasks[modelID] = task
        }
        persistState()
        task.resume()
    }

    func startDownload(modelID: String, resumeData: Data) {
        log.info("GGUF: Resuming download for '\(modelID, privacy: .public)'")
        let task = session.downloadTask(withResumeData: resumeData)
        mapQueue.sync {
            taskModelMap[task.taskIdentifier] = modelID
            activeTasks[modelID] = task
        }
        persistState()
        task.resume()
    }

    /// Cancel the running download for `modelID` and persist resume data to
    /// UserDefaults so a future `startDownload(modelID:resumeData:)` can pick
    /// up where it left off.
    func cancelDownload(modelID: String) {
        log.info("GGUF: Cancelling download for '\(modelID, privacy: .public)'")
        let task: URLSessionDownloadTask? = mapQueue.sync {
            // Remove the reverse mapping entries for this model.
            let staleKeys = taskModelMap.compactMap { k, v -> Int? in v == modelID ? k : nil }
            for k in staleKeys { taskModelMap.removeValue(forKey: k) }
            // Drop the throttle timestamp too — otherwise the dict
            // grows monotonically with the number of distinct model
            // IDs the process has ever downloaded.
            lastProgressYield.removeValue(forKey: modelID)
            return activeTasks.removeValue(forKey: modelID)
        }
        persistState()
        task?.cancel(byProducingResumeData: { data in
            if let data {
                UserDefaults.standard.set(
                    data, forKey: "com.homehub.app.resumeData.\(modelID)"
                )
            }
        })
    }

    /// Called by `AppDelegate` when the system delivers background session
    /// events to the app. Must be forwarded to the session via
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    func storeSystemCompletionHandler(_ handler: @escaping () -> Void) {
        mapQueue.sync { systemCompletionHandler = handler }
    }

    // MARK: - Persistence

    private func persistState() {
        let snapshot = mapQueue.sync { taskModelMap }
        store.save(GGUFManifest(
            version: GGUFManifest.currentVersion,
            tasks: snapshot.mapKeys { String($0) }
        ))
    }

    private func restorePersistedState() {
        // One-time migration from Wave 1 UserDefaults persistence.
        if let old = UserDefaults.standard.data(forKey: Self.legacyUDKey) {
            UserDefaults.standard.removeObject(forKey: Self.legacyUDKey)
            if let decoded = try? JSONDecoder().decode([String: String].self, from: old) {
                let intKeyed = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v -> (Int, String)? in
                    guard let i = Int(k) else { return nil }
                    return (i, v)
                })
                mapQueue.sync { taskModelMap = intKeyed }
                log.info("GGUF: Migrated \(intKeyed.count) tasks from UserDefaults to manifest")
                persistState()
                return
            }
        }

        guard let manifest = store.load() else { return }
        let intKeyed = Dictionary(uniqueKeysWithValues: manifest.tasks.compactMap { k, v -> (Int, String)? in
            guard let i = Int(k) else { return nil }
            return (i, v)
        })
        mapQueue.sync { taskModelMap = intKeyed }
        log.info("GGUF: Restored \(intKeyed.count) task entries from manifest v\(manifest.version)")
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadCoordinator: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let modelID = mapQueue.sync(execute: { taskModelMap[downloadTask.taskIdentifier] }) else { return }

        // totalBytesExpectedToWrite == -1 (NSURLSessionTransferSizeUnknown) when
        // the server uses chunked transfer encoding or sends no Content-Length
        // header (common with signed redirect chains). In that case we skip the
        // fractional progress update — the caller's UI shows an indeterminate
        // indicator — but we still fire the 100 ms throttle check so the
        // completion callback arrives cleanly at the end.
        guard totalBytesExpectedToWrite > 0 else {
            log.debug("GGUF: '\(modelID, privacy: .public)' — chunked / unknown-length transfer, \(totalBytesWritten) B written so far")
            return
        }

        let fraction = min(
            Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0
        )

        // Throttle updates to ~10 Hz (100 ms) to prevent MainActor spam.
        let now = ContinuousClock.now
        let last = mapQueue.sync { lastProgressYield[modelID] }
        if let last, now < last + .milliseconds(100) { return }

        mapQueue.sync { lastProgressYield[modelID] = now }
        Task { @MainActor [weak self] in self?.onProgress?(modelID, fraction) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let modelID = mapQueue.sync(execute: {
            taskModelMap[downloadTask.taskIdentifier]
        }) else { return }

        mapQueue.sync {
            taskModelMap.removeValue(forKey: downloadTask.taskIdentifier)
            activeTasks.removeValue(forKey: modelID)
            lastProgressYield.removeValue(forKey: modelID)
        }
        persistState()

        // Reject non-2xx HTTP responses before we pretend the download succeeded.
        // `URLSession.downloadTask` happily saves a 401/403/404 body to disk as
        // a "successful" download, which would otherwise end up on disk with a
        // .gguf extension.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let err = URLError(
                .badServerResponse,
                userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode). The URL may be gated, require authentication, or be wrong."]
            )
            log.error("GGUF: Non-2xx HTTP \(http.statusCode) for '\(modelID, privacy: .public)'")
            Task { @MainActor [weak self] in self?.onFailed?(modelID, err, nil) }
            return
        }

        // The system deletes `location` when this method returns — move it
        // SYNCHRONOUSLY to a stable temp path before that happens. Using
        // moveItem (not copyItem) avoids doubling I/O for large files and is
        // atomic within the same APFS volume. The move MUST succeed before we
        // return from the delegate, otherwise the temp file is gone and the
        // finalizer will see a missing file.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).gguf")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            log.error("GGUF: moveItem failed for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            Task { @MainActor [weak self] in self?.onFailed?(modelID, error, nil) }
            return
        }

        log.info("GGUF: Download complete for '\(modelID, privacy: .public)'")
        Task { @MainActor [weak self] in self?.onCompleted?(modelID, dest) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        guard let modelID = mapQueue.sync(execute: {
            taskModelMap[task.taskIdentifier]
        }) else { return }

        mapQueue.sync {
            taskModelMap.removeValue(forKey: task.taskIdentifier)
            activeTasks.removeValue(forKey: modelID)
            lastProgressYield.removeValue(forKey: modelID)
        }
        persistState()

        log.error("GGUF: Task failed for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        let resumeData = (error as? URLError)?.downloadTaskResumeData
        Task { @MainActor [weak self] in self?.onFailed?(modelID, error, resumeData) }
    }

    /// Called after the session delivers all queued events. The system
    /// completion handler must be called on the main thread so iOS can
    /// update the app snapshot.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler: (() -> Void)? = mapQueue.sync {
            let h = systemCompletionHandler
            systemCompletionHandler = nil
            return h
        }
        log.info("GGUF: Background session finished delivering events")
        DispatchQueue.main.async { handler?() }
    }
}

// MARK: - Dictionary helper

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
