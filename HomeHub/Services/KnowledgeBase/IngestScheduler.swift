import Foundation
import BackgroundTasks
import UIKit

/// Bridges the ingest pipeline to UIKit lifecycle + BackgroundTasks.
///
/// ## Two paths into the pipeline
/// 1. **Foreground drain.** Called from `AppContainer.bootstrap()`
///    and on `scenePhase == .active`. Picks up any job that was
///    `processing` when the app died, plus everything queued by
///    the Share Extension since last launch.
/// 2. **`BGProcessingTask`.** Scheduled on `.background` whenever
///    there are pending jobs. iOS picks an opportunistic moment
///    (typically when on charger + Wi-Fi) and gives us up to a
///    few minutes of CPU. Apple documents this as the right tier
///    for ML / indexing / DB-cleanup workloads — exactly our
///    profile. We drain in batches small enough to fit the budget
///    and persist progress between batches so an `expirationHandler`
///    fire doesn't lose work.
///
/// Background scheduling is opportunistic — the foreground drain
/// is the *guaranteed* path that always eventually runs. If iOS
/// never grants the BG task, the user just sees ingest finish
/// next time they open the app.
@MainActor
final class IngestScheduler {

    /// Identifier used both at registration time and for scheduling.
    /// Must match the value in `BGTaskSchedulerPermittedIdentifiers`
    /// in Info.plist (set via `INFOPLIST_KEY_*` in `project.yml`).
    static let backgroundTaskIdentifier = "cz.keksiczek.homehub.ingest"

    private let pipeline: IngestPipeline
    private let jobStore: IngestJobStore
    private var didRegister = false

    init(pipeline: IngestPipeline, jobStore: IngestJobStore) {
        self.pipeline = pipeline
        self.jobStore = jobStore
    }

    // MARK: - Registration
    //
    // BGTaskScheduler.register MUST be called before the app finishes
    // launching (i.e. before `application(_:didFinishLaunchingWithOptions:)`
    // returns). For SwiftUI lifecycle that means: from
    // `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    // Calling later → `Error Domain=BGTaskSchedulerErrorDomain Code=1`.

    /// Registers the BG task handler. Safe to call multiple times —
    /// the actual `BGTaskScheduler.register` is gated by
    /// `didRegister` so we don't trip "task identifier already
    /// registered" assertions.
    func registerHandlers() {
        guard !didRegister else { return }
        didRegister = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self,
                  let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // Hop to MainActor so we can talk to scheduler state.
            Task { @MainActor in
                await self.handleBGTask(processing)
            }
        }
    }

    // MARK: - Scheduling

    /// Submits a `BGProcessingTaskRequest`. Called when the app
    /// enters the background and there's pending work. Pre-iOS
    /// would have used `UIApplication.beginBackgroundTask` here,
    /// but `BGProcessingTask` is the explicitly recommended tier
    /// for "long, deferrable processing" like indexing — that's
    /// us.
    func scheduleIfNeeded() {
        Task { [jobStore] in
            let pending = (try? await jobStore.pendingCount()) ?? 0
            guard pending > 0 else { return }

            let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
            // The pipeline only does CPU + disk; no network needed
            // for embeddings. Setting these false maximises the
            // chance iOS schedules us soon (charger isn't required
            // for non-network ML workloads).
            request.requiresNetworkConnectivity = false
            request.requiresExternalPower = false
            request.earliestBeginDate = Date(timeIntervalSinceNow: 30)

            do {
                try BGTaskScheduler.shared.submit(request)
                HHLog.kb.notice("scheduled ingest BG task; pending=\(pending, privacy: .public)")
            } catch {
                HHLog.kb.error("BGTaskScheduler.submit failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Cancels every pending submission. Useful when the queue is
    /// drained during a foreground session — leaving stale requests
    /// just makes iOS schedule us for nothing.
    func cancelPendingSchedules() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
    }

    // MARK: - Drain

    /// Foreground-side drain: best-effort, never blocks the UI for
    /// long. Awaits at most one full pipeline pass over current
    /// pending jobs.
    func drainForegroundIfPending() async {
        let pending = (try? await jobStore.pendingCount()) ?? 0
        guard pending > 0 else { return }
        await pipeline.drainPending(maxJobs: 32, shouldContinue: { true })
    }

    // MARK: - BG handler

    private func handleBGTask(_ task: BGProcessingTask) async {
        // `expired` lives on a sendable atomic so the expiration
        // handler (which fires on a background queue) can flip it
        // and the running pipeline picks up the change between
        // chunk batches.
        let expired = ExpirationFlag()
        task.expirationHandler = {
            expired.set()
            HHLog.kb.notice("BG ingest task expired")
        }

        let finished = await pipeline.drainPending(
            maxJobs: 64,
            shouldContinue: { !expired.isSet }
        )
        HHLog.kb.notice("BG ingest task drained \(finished, privacy: .public) jobs")

        // Re-schedule if there's still work — iOS won't auto-renew
        // BG tasks for us.
        let stillPending = (try? await jobStore.pendingCount()) ?? 0
        if stillPending > 0 {
            scheduleIfNeeded()
        }
        task.setTaskCompleted(success: !expired.isSet)
    }
}

/// Trivial atomic-ish flag used to bridge the BG `expirationHandler`
/// closure (which fires on a Dispatch queue) with the actor-bound
/// pipeline. `OSAllocatedUnfairLock` would be overkill — the only
/// operations are "set true once" and "read".
private final class ExpirationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
