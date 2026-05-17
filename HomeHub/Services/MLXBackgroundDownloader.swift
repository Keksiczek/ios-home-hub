import Foundation
import os

/// Tracks all files for one MLX model download.
struct MLXDownloadJob: Codable, Sendable {
    var modelID: String
    var repoId: String
    var cacheDirPath: String          // absolute path — Documents/huggingface/models/{repoId}
    var files: [HFFileEntry]          // all files to download
    var completedFiles: Set<String>   // rfilenames that finished successfully
    var totalBytes: Int64             // sum of known file sizes (0 = unknown)
    var downloadedBytes: Int64        // running tally across all files

    var progress: Double {
        guard !files.isEmpty else { return 0 }
        if totalBytes > 0 {
            return min(1, Double(downloadedBytes) / Double(totalBytes))
        }
        return Double(completedFiles.count) / Double(files.count)
    }

    var isComplete: Bool { completedFiles.count >= files.count }
}

/// Ties a URLSession task back to a specific file within a model download.
private struct MLXFileTask: Codable, Sendable {
    var modelID: String
    var rfilename: String       // "model.safetensors", "config.json", …
    var destinationPath: String // absolute path to write the completed file
}

// MARK: -

/// Background multi-file downloader for MLX model repos.
///
/// An MLX model is a directory of files (config.json, tokenizer files,
/// one or more .safetensors weight shards). This service downloads every
/// required file via a **background** `URLSession` so downloads continue
/// even when the screen is off or the user switches apps.
///
/// ## Architecture
/// Mirrors `BackgroundDownloadCoordinator` but is extended to handle N
/// parallel file downloads per model:
///
/// - `taskMap`  (`[Int: MLXFileTask]`)   — URLSession taskIdentifier → file info
/// - `jobMap`   (`[String: MLXDownloadJob]`) — modelID → aggregate job state
///
/// Both maps are persisted to `UserDefaults` so in-progress downloads can
/// be reconnected after the app is relaunched by the system.
///
/// ## Thread safety
/// Marked `@unchecked Sendable`. All mutable state is exclusively accessed
/// through `serialQueue`; delegate callbacks (which arrive on a private
/// URLSession queue) synchronise through `serialQueue.sync`.
/// The `@Published` properties and callbacks are always updated on
/// `@MainActor`.
///
/// ## Concurrency contract — read this before adding sync calls
///
/// The class has 20+ `serialQueue.sync` call sites, which is a deadlock
/// risk pattern when the locked queue is reentered. The invariants:
///
/// 1. **Never call URLSession APIs from inside `serialQueue.sync`.**
///    URLSession dispatches its own delegate callbacks back through
///    `serialQueue.sync`; touching it inside our critical section
///    creates a `serialQueue → URLSession-queue → serialQueue` cycle.
///    The `cancelDownload` site is the canonical example: we drain
///    the maps under `sync`, then issue cancels via
///    `getTasksWithCompletionHandler` *outside* the block.
///
/// 2. **Never await inside `serialQueue.sync`.**
///    The closure runs synchronously on whichever caller thread we're
///    on. An await would suspend with the queue held; the resuming
///    thread would block forever waiting for the queue.
///
/// 3. **Never re-enter from the same thread.**
///    `DispatchQueue.sync` reentrancy is fatal on serial queues.
///    Splitting a `sync { … sync { … } }` into two separate blocks
///    is the fix.
///
/// 4. **Critical sections are short.**
///    Mutate the maps and return. Side effects (file IO, persistence,
///    `@Published` updates, callback fires) happen *after* the block.
///
/// Helpers `serialRead(_:)` / `serialMutate(_:)` exist to make these
/// invariants visible at the call site instead of a bare `sync`.
final class MLXBackgroundDownloader: NSObject, ObservableObject, BackgroundDownloadProgressing, @unchecked Sendable {

    static let shared = MLXBackgroundDownloader()
    static let sessionID = "com.homehub.app.mlxfiles.v1"

    private let log = Logger(subsystem: "com.homehub.app", category: "MLXBackgroundDownloader")

    // MARK: - Published state (always mutated on @MainActor)

    /// Per-model download progress, 0 … 1.
    @Published private(set) var downloadProgress: [String: Double] = [:]
    /// Model IDs that are currently downloading (set cleared on completion / failure).
    @Published private(set) var activeDownloads: Set<String> = []

    // MARK: - Callbacks (set by ModelDownloadService; called on @MainActor)

    var onProgress:  (@MainActor (String, Double) -> Void)?
    var onCompleted: (@MainActor (String) -> Void)?   // fired when ALL files land
    var onFailed:    (@MainActor (String, Error) -> Void)?

    // MARK: - Background session (lazy — created after callbacks are wired)

    private(set) lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Internal state (guarded by serialQueue)

    private let serialQueue = DispatchQueue(
        label: "com.homehub.mlxdownloader.serial", qos: .utility
    )

    /// Read-style critical section. Returns a `Sendable` snapshot of
    /// internal state for use *outside* the queue. Use this when
    /// the only thing inside the closure is reading + projecting.
    /// In debug builds asserts the queue is not already held by the
    /// current thread (a re-entrant `sync` is fatal on serial queues).
    private func serialRead<T>(_ body: () -> T) -> T {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(serialQueue))
        #endif
        return serialQueue.sync(execute: body)
    }

    /// Mutation critical section. Same contract as `serialRead`,
    /// but the closure name documents intent at the call site.
    /// `@discardableResult` because most mutations don't need to
    /// publish a return value.
    @discardableResult
    private func serialMutate<T>(_ body: () -> T) -> T {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(serialQueue))
        #endif
        return serialQueue.sync(execute: body)
    }
    /// URLSession taskIdentifier → which file it is downloading.
    private var taskMap: [Int: MLXFileTask] = [:]
    /// modelID → aggregate download job.
    private var jobMap: [String: MLXDownloadJob] = [:]
    /// Progress-throttle timestamps (per model).
    private var lastProgressYield: [String: ContinuousClock.Instant] = [:]
    /// System background-session completion handler stored by AppDelegate.
    private var systemCompletionHandler: (() -> Void)?

    // MARK: - Manifest

    private struct MLXManifest: Codable {
        static let currentVersion = 1
        var version: Int
        var tasks: [String: MLXFileTask]    // String(taskIdentifier) → MLXFileTask
        var jobs: [String: MLXDownloadJob]  // modelID → MLXDownloadJob
    }

    private let store = ManifestStore<MLXManifest>.appSupport(filename: "mlx-download-manifest.json")

    // One-time migration keys from UserDefaults persistence.
    private static let legacyUDTaskKey = "com.homehub.mlx.taskMap"
    private static let legacyUDJobKey  = "com.homehub.mlx.jobMap"

    // MARK: - Init

    private override init() {
        super.init()
        restorePersistedState()
    }

    // MARK: - Public API

    /// Model IDs currently tracked in the in-memory job map.
    ///
    /// Read by `DownloadManager.wireAndReconnect()` to seed `activeModelIDs`
    /// before the async `reconnect()` call fires — so `isActive()` /
    /// `isDownloading()` return `true` for any URLSession tasks that survived
    /// an OS kill while the app was dead. Orphan recovery in `reconnect()`
    /// will call `onFailed` for stale IDs and `markFinished` will prune them.
    var manifestModelIDs: Set<String> {
        serialRead { Set(jobMap.keys) }
    }

    /// Forces session creation and reconnects to any in-flight background tasks
    /// from a previous app launch. Call after `onProgress/onCompleted/onFailed`
    /// are wired.
    func reconnect() {
        _ = session          // ensures the lazy property is initialised
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            guard let self else { return }
            let existing = self.serialRead { self.taskMap }
            let liveIDs = Set(downloadTasks.map { $0.taskIdentifier })

            self.log.info("MLX: reconnect — manifest=\(existing.count) live=\(liveIDs.count)")

            // Orphan recovery: manifest tasks whose URLSession task is gone.
            var orphanModelIDs: Set<String> = []
            var orphanTIDs: [Int] = []
            for (tid, ft) in existing where !liveIDs.contains(tid) {
                orphanModelIDs.insert(ft.modelID)
                orphanTIDs.append(tid)
            }
            if !orphanTIDs.isEmpty {
                self.serialMutate {
                    for tid in orphanTIDs { self.taskMap.removeValue(forKey: tid) }
                    for modelID in orphanModelIDs { self.jobMap.removeValue(forKey: modelID) }
                }
                self.persistState()
                let err = URLError(
                    .networkConnectionLost,
                    userInfo: [NSLocalizedDescriptionKey: "Download was interrupted while the app was stopped."]
                )
                for modelID in orphanModelIDs {
                    self.log.warning("MLX: Orphaned download for '\(modelID, privacy: .public)' — tasks not in nsurlsessiond; notifying failed")
                    Task { @MainActor [weak self] in self?.onFailed?(modelID, err) }
                }
            }

            // Unrecognised live tasks: in URLSession but absent from manifest.
            // Should not happen in normal operation — log and leave to time out.
            var resumed = 0
            for task in downloadTasks {
                guard let ft = existing[task.taskIdentifier] else {
                    self.log.notice("MLX: Unrecognised live task \(task.taskIdentifier) — no manifest entry, leaving to time out")
                    continue
                }
                self.log.info("MLX: Resumed task \(task.taskIdentifier) ('\(ft.rfilename, privacy: .public)') for '\(ft.modelID, privacy: .public)'")
                Task { @MainActor [weak self] in self?.activeDownloads.insert(ft.modelID) }
                resumed += 1
            }
            self.log.info("MLX: reconnect complete — orphans=\(orphanModelIDs.count) resumed=\(resumed)")
        }
    }

    /// Starts background downloads for all files in `files`.
    ///
    /// - Parameters:
    ///   - modelID:  catalog model ID (e.g. `"mlx-llama-3.2-1b-it"`).
    ///   - repoId:   HF repo (e.g. `"mlx-community/Llama-3.2-1B-Instruct-4bit"`).
    ///   - cacheDir: destination directory (Documents/huggingface/models/{repoId}).
    ///   - files:    file list from `HuggingFaceAPIClient.fetchModelFiles`.
    @MainActor
    func startDownload(
        modelID: String,
        repoId: String,
        cacheDir: URL,
        files: [HFFileEntry]
    ) {
        guard !files.isEmpty else {
            log.error("MLX: No files to download for '\(modelID, privacy: .public)'")
            return
        }

        let totalBytes = files.compactMap(\.size).reduce(Int64(0), +)
        let job = MLXDownloadJob(
            modelID: modelID,
            repoId: repoId,
            cacheDirPath: cacheDir.path,
            files: files,
            completedFiles: [],
            totalBytes: totalBytes,
            downloadedBytes: 0
        )

        let staleTIDs: Set<Int> = serialMutate {
            // If a previous job exists for this model, cancel its tasks first.
            let ids = Set(taskMap.filter { $0.value.modelID == modelID }.keys)
            for k in ids { taskMap.removeValue(forKey: k) }
            jobMap[modelID] = job
            return ids
        }
        persistState()

        // Cancel any in-flight URLSession tasks we just orphaned in the
        // manifest. Without this, the previous attempt's URLSessionDownloadTask
        // would happily race the new tasks for the same destination paths —
        // the loser's `moveItem` overwrites the winner's bytes mid-flight.
        // Issued OUTSIDE the serial queue (per the concurrency contract at
        // the top of this file).
        if !staleTIDs.isEmpty {
            log.info("MLX: cancelling \(staleTIDs.count) stale URLSession task(s) for restart of '\(modelID, privacy: .public)'")
            session.getAllTasks { tasks in
                for t in tasks where staleTIDs.contains(t.taskIdentifier) {
                    t.cancel()
                }
            }
        }

        activeDownloads.insert(modelID)
        downloadProgress[modelID] = 0

        // Enqueue one background URLSessionDownloadTask per file.
        for file in files {
            let destPath = cacheDir
                .appendingPathComponent(file.rfilename)
                .path
            let downloadURL = HuggingFaceAPIClient.downloadURL(repoId: repoId, filename: file.rfilename)

            let task = session.downloadTask(with: downloadURL)
            let fileTask = MLXFileTask(
                modelID: modelID,
                rfilename: file.rfilename,
                destinationPath: destPath
            )
            serialQueue.sync {
                taskMap[task.taskIdentifier] = fileTask
            }
            task.resume()
            log.debug("MLX: Enqueued '\(file.rfilename, privacy: .public)' for '\(modelID, privacy: .public)'")
        }

        persistState()
        log.info("MLX: Started \(files.count) background downloads for '\(modelID, privacy: .public)'")
    }

    /// Cancels all in-flight file downloads for `modelID`.
    func cancelDownload(modelID: String) {
        // Capture task IDs BEFORE clearing the map — if we cleared first,
        // the getAllTasks callback would find taskMap empty and cancel nothing.
        let idsToCancel: Set<Int> = serialMutate {
            let ids = Set(taskMap.filter { $0.value.modelID == modelID }.keys)
            for id in ids { taskMap.removeValue(forKey: id) }
            jobMap.removeValue(forKey: modelID)
            // Drop the throttle entry along with the rest — without this
            // the dict grows unbounded across distinct model IDs.
            lastProgressYield.removeValue(forKey: modelID)
            return ids
        }
        persistState()
        if !idsToCancel.isEmpty {
            session.getAllTasks { tasks in
                for task in tasks where idsToCancel.contains(task.taskIdentifier) {
                    task.cancel()
                }
            }
        }
        Task { @MainActor [weak self] in
            self?.activeDownloads.remove(modelID)
            self?.downloadProgress.removeValue(forKey: modelID)
        }
        log.info("MLX: Cancelled \(idsToCancel.count) tasks for '\(modelID, privacy: .public)'")
    }

    /// Called by `AppDelegate` when the system wakes the app for this session.
    func storeSystemCompletionHandler(_ handler: @escaping () -> Void) {
        serialQueue.sync { systemCompletionHandler = handler }
    }

    // MARK: - Persistence

    private func persistState() {
        let (tasks, jobs) = serialRead { (taskMap, jobMap) }
        store.save(MLXManifest(
            version: MLXManifest.currentVersion,
            tasks: tasks.mapKeys { String($0) },
            jobs: jobs
        ))
    }

    private func restorePersistedState() {
        let ud = UserDefaults.standard
        // One-time migration from UserDefaults persistence.
        if ud.data(forKey: Self.legacyUDTaskKey) != nil || ud.data(forKey: Self.legacyUDJobKey) != nil {
            let decoder = JSONDecoder()
            if let taskData = ud.data(forKey: Self.legacyUDTaskKey),
               let decoded = try? decoder.decode([String: MLXFileTask].self, from: taskData) {
                let intKeyed = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v -> (Int, MLXFileTask)? in
                    guard let i = Int(k) else { return nil }
                    return (i, v)
                })
                serialMutate { taskMap = intKeyed }
            }
            if let jobData = ud.data(forKey: Self.legacyUDJobKey),
               let decoded = try? decoder.decode([String: MLXDownloadJob].self, from: jobData) {
                serialMutate { jobMap = decoded }
            }
            ud.removeObject(forKey: Self.legacyUDTaskKey)
            ud.removeObject(forKey: Self.legacyUDJobKey)
            let count = serialRead { taskMap.count }
            log.info("MLX: Migrated \(count) tasks from UserDefaults to manifest")
            persistState()
            return
        }

        guard let manifest = store.load() else { return }
        let intKeyed = Dictionary(uniqueKeysWithValues: manifest.tasks.compactMap { k, v -> (Int, MLXFileTask)? in
            guard let i = Int(k) else { return nil }
            return (i, v)
        })
        serialMutate {
            taskMap = intKeyed
            jobMap = manifest.jobs
        }
        log.info("MLX: Restored \(intKeyed.count) tasks from manifest v\(manifest.version)")
    }
}

// MARK: - Dictionary helper

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

// MARK: - URLSessionDownloadDelegate

extension MLXBackgroundDownloader: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let modelID: String = serialQueue.sync {
            guard let ft = taskMap[downloadTask.taskIdentifier] else { return "" }
            return ft.modelID
        }
        guard !modelID.isEmpty else { return }

        // Update running byte tally for the job
        serialQueue.sync {
            guard var job = jobMap[modelID] else { return }
            // Add bytes written since last callback (delta approach)
            // Simple: recompute from all completed files + current file progress
            let completedBytes = job.files
                .filter { job.completedFiles.contains($0.rfilename) }
                .compactMap(\.size)
                .reduce(Int64(0), +)
            let currentFileBytes = totalBytesExpectedToWrite > 0 ? totalBytesWritten : 0
            job.downloadedBytes = completedBytes + currentFileBytes
            jobMap[modelID] = job
        }

        // Throttle to 200 ms
        let now = ContinuousClock.now
        let lastYield = serialQueue.sync { lastProgressYield[modelID] }
        guard lastYield == nil || now >= lastYield! + .milliseconds(200) else { return }
        serialQueue.sync { lastProgressYield[modelID] = now }

        let fraction: Double = serialQueue.sync { jobMap[modelID]?.progress ?? 0 }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.downloadProgress[modelID] = fraction
            self.onProgress?(modelID, fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fileTask: MLXFileTask? = serialQueue.sync {
            taskMap[downloadTask.taskIdentifier]
        }
        guard let fileTask else { return }

        // Validate HTTP status before accepting the file.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let err = URLError(
                .badServerResponse,
                userInfo: [NSLocalizedDescriptionKey:
                    "Server returned HTTP \(http.statusCode) for \(fileTask.rfilename)"]
            )
            log.error("MLX: HTTP \(http.statusCode) for '\(fileTask.rfilename, privacy: .public)'")
            handleFileFailure(fileTask: fileTask, error: err)
            return
        }

        // Move file to destination — must happen before returning (system deletes `location`).
        let dest = URL(fileURLWithPath: fileTask.destinationPath)
        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            log.error("MLX: File move failed for '\(fileTask.rfilename, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            handleFileFailure(fileTask: fileTask, error: error)
            return
        }

        // Mark file complete in job.
        let jobComplete: Bool = serialQueue.sync {
            taskMap.removeValue(forKey: downloadTask.taskIdentifier)
            guard var job = jobMap[fileTask.modelID] else { return false }
            job.completedFiles.insert(fileTask.rfilename)
            // Recompute downloaded bytes now that this file is done
            let completedBytes = job.files
                .filter { job.completedFiles.contains($0.rfilename) }
                .compactMap(\.size)
                .reduce(Int64(0), +)
            job.downloadedBytes = completedBytes
            jobMap[fileTask.modelID] = job
            return job.isComplete
        }
        persistState()

        let fraction: Double = serialQueue.sync { jobMap[fileTask.modelID]?.progress ?? 1 }
        let modelID = fileTask.modelID
        log.info("MLX: File '\(fileTask.rfilename, privacy: .public)' complete for '\(modelID, privacy: .public)'")

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.downloadProgress[modelID] = fraction
            self.onProgress?(modelID, fraction)

            if jobComplete {
                // `removeValue` returns the evicted value, which we don't
                // need — explicit `_ =` keeps Swift 6 strict-concurrency
                // unused-result warnings quiet.
                self.serialQueue.sync {
                    self.jobMap.removeValue(forKey: modelID)
                    self.lastProgressYield.removeValue(forKey: modelID)
                }
                self.persistState()
                self.activeDownloads.remove(modelID)
                self.downloadProgress.removeValue(forKey: modelID)
                self.onCompleted?(modelID)
                self.log.info("MLX: All files complete for '\(modelID, privacy: .public)'")
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let fileTask: MLXFileTask? = serialQueue.sync {
            taskMap[task.taskIdentifier]
        }
        guard let fileTask else { return }
        log.error("MLX: Task failed for '\(fileTask.rfilename, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        handleFileFailure(fileTask: fileTask, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        let handler: (() -> Void)? = serialQueue.sync {
            let h = systemCompletionHandler
            systemCompletionHandler = nil
            return h
        }
        log.info("MLX: Background session finished delivering events; calling system completion handler: \(handler != nil)")
        DispatchQueue.main.async { handler?() }
    }

    // MARK: - Error path

    private func handleFileFailure(fileTask: MLXFileTask, error: Error) {
        let modelID = fileTask.modelID
        serialQueue.sync {
            let stale = taskMap.filter { $0.value.modelID == modelID }.map(\.key)
            for k in stale { taskMap.removeValue(forKey: k) }
            jobMap.removeValue(forKey: modelID)
            lastProgressYield.removeValue(forKey: modelID)
        }
        persistState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activeDownloads.remove(modelID)
            self.downloadProgress.removeValue(forKey: modelID)
            self.onFailed?(modelID, error)
        }
    }

}
