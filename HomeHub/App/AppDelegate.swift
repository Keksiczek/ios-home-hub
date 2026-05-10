import UIKit

/// Minimal UIApplicationDelegate. Two responsibilities:
///
/// 1. Receive `handleEventsForBackgroundURLSession` and forward to
///    the matching download coordinator. Required even in SwiftUI
///    lifecycle apps.
/// 2. Register `BGTaskScheduler` handlers before launch finishes.
///    iOS asserts hard if `BGTaskScheduler.register(forTaskWithIdentifier:)`
///    is called after `application(_:didFinishLaunchingWithOptions:)`
///    returns, which is why this can't live in `AppContainer.bootstrap()`
///    (that runs from the SwiftUI `.task` modifier on the root view,
///    after launch completion).
///
/// Background sessions in use:
/// - `BackgroundDownloadCoordinator` — single-file GGUF downloads
/// - `MLXBackgroundDownloader`       — multi-file MLX weight downloads
///
/// Background tasks in use:
/// - `IngestScheduler.backgroundTaskIdentifier` — Knowledge Base
///   ingest pipeline (parsing, chunking, embedding)
///
/// Wired into the app via `@UIApplicationDelegateAdaptor` in `HomeHubApp`.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // BGTaskScheduler.register MUST be called before this method
        // returns — Apple terminates the app if registration happens
        // any later. UIApplicationDelegate callbacks always run on
        // the main thread, which is also the MainActor's executor,
        // so we can synchronously bridge across the isolation
        // boundary via `assumeIsolated`. AppContainer.shared is a
        // lazy `static let`; touching it here forces the wiring to
        // complete in time for the registration call.
        MainActor.assumeIsolated {
            AppContainer.shared.knowledgeBaseService.scheduler?.registerHandlers()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Routing through `BackgroundDownloadRouting` instead of a
        // hard-coded switch keeps this delegate honest as new
        // download stacks are added — they just conform to
        // `BackgroundDownloadProgressing` and append to
        // `BackgroundDownloadRouting.all`. If no downloader claims
        // the identifier we still call the handler so the system
        // watchdog doesn't terminate the app.
        MainActor.assumeIsolated {
            let dispatched = BackgroundDownloadRouting
                .dispatchSystemCompletionHandler(for: identifier, completionHandler)
            if !dispatched {
                completionHandler()
            }
        }
    }
}
