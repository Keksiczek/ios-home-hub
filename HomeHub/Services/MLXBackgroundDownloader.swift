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
    /// taskIdentifier → bytes written so far for the *in-flight* file.
    /// Summed across ALL of a model's active tasks when computing
    /// progress — using only the single firing task's byte count made
    /// the bar jump erratically while several files downloaded in
    /// parallel. Cleared when a task completes / fails. Not persisted:
    /// in-flight byte counts restart from the system on relaunch.
    private var inFlightBytes: [Int: Int64] = [:]
    /// "modelID|rfilename" → consecutive transient-failure count. Lets a
    /// single flaky file retry a few times instead of tearing down the
    /// whole multi-file model download on the first network blip.
    private var fileRetryCounts: [String: Int] = [:]
    /// Max transient retries per file before the whole job is failed.
    private static let maxFileRetries = 3
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

            // Use a URLRequest so we can stamp the Authorization header
            // for gated repos. URLSessionDownloadTask honours per-request
            // headers under the background session just like a foreground
            // session would. The header is whitespace-trimmed and may be
            // absent — anonymous downloads of public weights work as before.
            var fileRequest = URLRequest(url: downloadURL)
            HuggingFaceAPIClient.applyAuthorization(to: &fileRequest)
            let task = session.downloadTask(with: fileRequest)
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

        // Update running byte tally for the job. We sum:
        //   completed-file sizes  +  in-flight bytes of EVERY active task
        // for this model. The previous version added only the single
        // firing task's `totalBytesWritten`, so with N files downloading
        // in parallel the bar reflected just one file at a time and
        // jumped around (and could appear to "start" partway through when
        // a large shard's callback landed first).
        serialQueue.sync {
            guard var job = jobMap[modelID] else { return }
            inFlightBytes[downloadTask.taskIdentifier] =
                totalBytesExpectedToWrite > 0 ? totalBytesWritten : 0
            let completedBytes = job.files
                .filter { job.completedFiles.contains($0.rfilename) }
                .compactMap(\.size)
                .reduce(Int64(0), +)
            let inflight = taskMap
                .filter { $0.value.modelID == modelID }
                .keys
                .reduce(Int64(0)) { $0 + (inFlightBytes[$1] ?? 0) }
            job.downloadedBytes = completedBytes + inflight
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
            // Use the shared HF status formatter so a 401 mid-download
            // says the same thing as a 401 at manifest time. The
            // `isAuthRelatedFailure` heuristic in `ModelsView` matches
            // the shared dictionary, so this also keeps the
            // "Otevřít Nastavení" CTA reliable across both paths.
            let userMessage = HFError.reasonForHTTPStatus(
                http.statusCode,
                context: fileTask.rfilename
            )
            let err = URLError(
                .badServerResponse,
                userInfo: [NSLocalizedDescriptionKey: userMessage]
            )
            log.error("MLX: HTTP \(http.statusCode) for '\(fileTask.rfilename, privacy: .public)'")
            // 429 (rate limit) and 5xx are worth retrying; 4xx (auth /
            // not-found) are permanent and should fail the job fast.
            let retryable = http.statusCode == 429 || (500..<600).contains(http.statusCode)
            handleFileFailure(fileTask: fileTask, error: err, transient: retryable)
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
            // Local filesystem failure (disk full, permissions) — not
            // worth retrying the network download.
            handleFileFailure(fileTask: fileTask, error: error, transient: false)
            return
        }

        // Mark file complete in job.
        let jobComplete: Bool = serialQueue.sync {
            taskMap.removeValue(forKey: downloadTask.taskIdentifier)
            inFlightBytes.removeValue(forKey: downloadTask.taskIdentifier)
            fileRetryCounts.removeValue(forKey: "\(fileTask.modelID)|\(fileTask.rfilename)")
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
                    self.fileRetryCounts = self.fileRetryCounts.filter { !$0.key.hasPrefix("\(modelID)|") }
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
        // A user/lifecycle cancellation arrives here as URLError.cancelled —
        // never retry it (the job was deliberately stopped) and don't fire
        // onFailed for it either: cancelDownload already cleaned up, so
        // jobMap[modelID] is gone and handleFileFailure will no-op to abort
        // with no active job (the @MainActor onFailed still fires but the
        // model is already back to .notInstalled). Guard explicitly.
        if (error as? URLError)?.code == .cancelled {
            log.info("MLX: Task cancelled for '\(fileTask.rfilename, privacy: .public)' — not retrying")
            return
        }
        log.error("MLX: Task failed for '\(fileTask.rfilename, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        handleFileFailure(fileTask: fileTask, error: error, transient: Self.isTransient(error))
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

    /// `true` for errors worth retrying the single file over (network
    /// drops, server 5xx / 429). Permanent failures (auth, 404, disk,
    /// cancellation) return `false` so the job fails fast instead of
    /// burning retries on something that will never succeed.
    private static func isTransient(_ error: Error) -> Bool {
        let urlErr = error as? URLError
        switch urlErr?.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Handles a single file's failure. Transient errors retry the file
    /// (up to `maxFileRetries`, with exponential backoff) so one flaky
    /// shard doesn't abort an otherwise-healthy multi-file download —
    /// the previous behaviour nuked the entire job on the first error,
    /// which is why large downloads "often didn't finish" on mobile
    /// networks. Permanent errors / exhausted retries fail the whole job.
    private func handleFileFailure(fileTask: MLXFileTask, error: Error, transient: Bool) {
        let modelID = fileTask.modelID
        let retryKey = "\(modelID)|\(fileTask.rfilename)"

        enum Decision { case retry(repoId: String, dest: String, attempt: Int); case abort }
        let decision: Decision = serialMutate {
            guard let job = jobMap[modelID] else { return .abort }
            let attempt = (fileRetryCounts[retryKey] ?? 0) + 1
            // Drop the dead task mapping for the failed file regardless
            // of the decision so it can't linger in `taskMap`.
            let deadTIDs = taskMap
                .filter { $0.value.modelID == modelID && $0.value.rfilename == fileTask.rfilename }
                .map(\.key)
            for k in deadTIDs {
                taskMap.removeValue(forKey: k)
                inFlightBytes.removeValue(forKey: k)
            }
            if transient && attempt <= Self.maxFileRetries {
                fileRetryCounts[retryKey] = attempt
                return .retry(repoId: job.repoId, dest: fileTask.destinationPath, attempt: attempt)
            }
            // Permanent / exhausted — tear down the whole job.
            let stale = taskMap.filter { $0.value.modelID == modelID }.map(\.key)
            for k in stale {
                taskMap.removeValue(forKey: k)
                inFlightBytes.removeValue(forKey: k)
            }
            jobMap.removeValue(forKey: modelID)
            lastProgressYield.removeValue(forKey: modelID)
            fileRetryCounts = fileRetryCounts.filter { !$0.key.hasPrefix("\(modelID)|") }
            return .abort
        }
        persistState()

        switch decision {
        case .retry(let repoId, let dest, let attempt):
            // Exponential backoff (1s, 2s, 4s) capped — re-enqueue OUTSIDE
            // the serial queue (URLSession contract #1). A fresh download
            // task replaces the dead one; the destination path is unchanged
            // so `didFinishDownloadingTo` lands it exactly where expected.
            let backoff = pow(2.0, Double(attempt - 1))
            log.notice("MLX: retrying '\(fileTask.rfilename, privacy: .public)' for '\(modelID, privacy: .public)' in \(backoff, format: .fixed(precision: 0))s (attempt \(attempt)/\(Self.maxFileRetries))")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + backoff) { [weak self] in
                guard let self else { return }
                // Bail if the job was cancelled / completed while we waited.
                let stillActive = self.serialRead { self.jobMap[modelID] != nil }
                guard stillActive else { return }
                let url = HuggingFaceAPIClient.downloadURL(repoId: repoId, filename: fileTask.rfilename)
                var request = URLRequest(url: url)
                HuggingFaceAPIClient.applyAuthorization(to: &request)
                let task = self.session.downloadTask(with: request)
                let newFileTask = MLXFileTask(
                    modelID: modelID,
                    rfilename: fileTask.rfilename,
                    destinationPath: dest
                )
                self.serialMutate { self.taskMap[task.taskIdentifier] = newFileTask }
                self.persistState()
                task.resume()
            }
        case .abort:
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeDownloads.remove(modelID)
                self.downloadProgress.removeValue(forKey: modelID)
                self.onFailed?(modelID, error)
            }
        }
    }

}
