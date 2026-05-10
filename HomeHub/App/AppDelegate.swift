import UIKit

/// Minimal UIApplicationDelegate added solely to receive
/// `handleEventsForBackgroundURLSession`. This is required even in
/// SwiftUI lifecycle apps to forward the system-provided completion
/// handler to the appropriate download coordinator.
///
/// Two background sessions are in use:
/// - `BackgroundDownloadCoordinator` — single-file GGUF downloads
/// - `MLXBackgroundDownloader`       — multi-file MLX weight downloads
///
/// Wired into the app via `@UIApplicationDelegateAdaptor` in `HomeHubApp`.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        switch identifier {
        case BackgroundDownloadCoordinator.sessionID:
            BackgroundDownloadCoordinator.shared.storeSystemCompletionHandler(completionHandler)
        case MLXBackgroundDownloader.sessionID:
            MLXBackgroundDownloader.shared.storeSystemCompletionHandler(completionHandler)
        default:
            // Unknown session — call immediately to avoid watchdog timeouts.
            completionHandler()
        }
    }
}
