import Foundation

/// Owns a single background `URLSession` for model downloads.
///
/// Downloads started through this coordinator continue in the background
/// when the app is suspended or killed by the OS. The system relaunches
/// the app (or delivers events to the existing process) when a download
/// completes, at which point `AppDelegate.handleEventsForBackgroundURLSession`
/// stores the system completion handler here.
///
/// Thread-safety: delegate callbacks from URLSession arrive on a private
/// queue; `mapQueue` serialises all access to shared mutable dictionaries.
/// All user-facing callbacks (`onProgress`, `onCompleted`, `onFailed`) are
/// dispatched back to `@MainActor` before being called.
final class BackgroundDownloadCoordinator: NSObject {

    static let shared = BackgroundDownloadCoordinator()
    static let sessionID = "com.homehub.app.modeldownload.v1"

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
    private var taskModelMap: [Int: String] = [:]
    /// Maps model ID → active download task (for synchronous cancel).
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    /// Stored by `AppDelegate` when the system wakes the app for this session.
    private var systemCompletionHandler: (() -> Void)?

    // MARK: - Callbacks (set once by ModelDownloadService; called on @MainActor)

    var onProgress: (@Sendable @MainActor (_ modelID: String, _ fraction: Double) -> Void)?
    var onCompleted: (@Sendable @MainActor (_ modelID: String, _ tempURL: URL) -> Void)?
    var onFailed: (@Sendable @MainActor (_ modelID: String, _ error: Error, _ resumeData: Data?) -> Void)?

    // MARK: - Init

    private override init() {
        super.init()
        // Touching `session` reconnects to any in-flight background session
        // from a previous app run, which triggers the delegate callbacks for
        // already-completed downloads.
        _ = session
    }

    // MARK: - Public API

    func startDownload(modelID: String, url: URL) {
        let task = session.downloadTask(with: url)
        mapQueue.sync {
            taskModelMap[task.taskIdentifier] = modelID
            activeTasks[modelID] = task
        }
        task.resume()
    }

    func startDownload(modelID: String, resumeData: Data) {
        let task = session.downloadTask(withResumeData: resumeData)
        mapQueue.sync {
            taskModelMap[task.taskIdentifier] = modelID
            activeTasks[modelID] = task
        }
        task.resume()
    }

    /// Cancel the running download for `modelID` and persist resume data to
    /// UserDefaults so a future `startDownload(modelID:resumeData:)` can pick
    /// up where it left off.
    func cancelDownload(modelID: String) {
        let task: URLSessionDownloadTask? = mapQueue.sync {
            activeTasks.removeValue(forKey: modelID)
        }
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
        guard
            let modelID = mapQueue.sync(execute: { taskModelMap[downloadTask.taskIdentifier] }),
            totalBytesExpectedToWrite > 0
        else { return }

        let fraction = min(
            Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0
        )
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
        }

        // The system deletes `location` when this method returns — copy it
        // synchronously to a stable temp path before that happens.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).gguf")
        try? FileManager.default.copyItem(at: location, to: dest)

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
        }

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
        DispatchQueue.main.async { handler?() }
    }
}
