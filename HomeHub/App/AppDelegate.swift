import UIKit

/// Minimal UIApplicationDelegate added solely to receive
/// `handleEventsForBackgroundURLSession`. This is required even in
/// SwiftUI lifecycle apps to forward the system-provided completion
/// handler to `BackgroundDownloadCoordinator`.
///
/// Wired into the app via `@UIApplicationDelegateAdaptor` in `HomeHubApp`.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloadCoordinator.sessionID else {
            // Unknown session — call immediately to avoid watchdog timeouts.
            completionHandler()
            return
        }
        // Forward to the coordinator; it will call the handler after
        // urlSessionDidFinishEvents(forBackgroundURLSession:) fires.
        BackgroundDownloadCoordinator.shared.storeSystemCompletionHandler(completionHandler)
    }
}
