import Foundation

/// Common observable surface for the two background download stacks
/// — `BackgroundDownloadCoordinator` (single-file GGUF) and
/// `MLXBackgroundDownloader` (multi-file MLX repos).
///
/// ## Why a protocol, not a unified class
/// The two backends have legitimately different shapes:
/// - GGUF is one file per model, so `startDownload(modelID:url:)` is
///   the natural API and `onCompleted` carries the temp URL where
///   the file landed.
/// - MLX models are a directory of N files (config, tokenizer,
///   .safetensors shards), each issued through a separate
///   `URLSession` task; the user-visible "completion" only fires
///   once *every* file lands and the directory is populated in
///   place.
///
/// Forcing both into one signature would either burn a list-of-one
/// allocation on every GGUF download or leak MLX-specific surface
/// into the simpler path. Instead, this protocol unifies the two
/// pieces every caller needs regardless of backend:
///
/// 1. The `sessionID` for `AppDelegate.application(_:handleEvents
///    ForBackgroundURLSession:completionHandler:)` routing.
/// 2. Observable progress / active-set state for SwiftUI.
/// 3. Cancellation + system-completion-handler plumbing.
///
/// `startDownload` stays specific to each backend's signature; UI
/// callers pick the right one by checking the model's format.
///
/// Both implementations already expose this surface — this protocol
/// just makes it explicit and lets generic UI code (e.g. an "any
/// downloads in flight?" badge) avoid branching by type.
// Not `@MainActor` because the two existing implementations don't
// mark themselves so — `BackgroundDownloadCoordinator` is a plain
// `NSObject` with `@Published` properties (read on main-actor by
// SwiftUI), and `MLXBackgroundDownloader` synchronises its own
// state through a serial dispatch queue. Marking the protocol
// `@MainActor` would require both classes to retrofit isolation,
// which is out of scope for this consolidation.
protocol BackgroundDownloadProgressing: AnyObject {
    /// `URLSessionConfiguration.background(withIdentifier:)` value.
    /// Static because `AppDelegate.application(_:handleEventsFor
    /// BackgroundURLSession:)` switches on this string before any
    /// instance is reachable.
    static var sessionID: String { get }

    /// Instance accessor for the static `sessionID`. Lets generic
    /// code dispatch through `[any BackgroundDownloadProgressing]`
    /// without having to know the concrete type to access the
    /// static property.
    var instanceSessionID: String { get }

    /// Cancels every URLSessionTask associated with `modelID`,
    /// drops the persisted job state, and clears progress.
    /// Idempotent — safe to call when no download exists.
    func cancelDownload(modelID: String)

    /// AppDelegate forwards the system completion handler here
    /// when iOS wakes the app for a background URLSession event.
    /// The downloader holds it and calls it after persisting state
    /// + firing user callbacks, telling iOS we're done with this
    /// wake-up. Skipping this triggers a watchdog termination.
    func storeSystemCompletionHandler(_ handler: @escaping () -> Void)
}

extension BackgroundDownloadProgressing {
    /// Default implementation — pulls the static value through.
    /// Concrete types satisfy this without writing it themselves.
    var instanceSessionID: String { Self.sessionID }
}

/// Routing helper used by `AppDelegate.application(_:handleEvents
/// ForBackgroundURLSession:completionHandler:)`. Lets the delegate
/// loop over registered downloaders by protocol instead of
/// hard-coding the two singletons; new download stacks plug in by
/// conforming + appending to the `all` list below.
enum BackgroundDownloadRouting {
    /// All known background download stacks. Order doesn't matter —
    /// `AppDelegate` matches by `sessionID`.
    @MainActor
    static var all: [any BackgroundDownloadProgressing] {
        [
            BackgroundDownloadCoordinator.shared,
            MLXBackgroundDownloader.shared
        ]
    }

    /// Hands the system completion handler to whichever downloader
    /// owns the given session identifier. Returns `true` if a
    /// matching downloader was found; `false` lets the delegate
    /// fall back to invoking the handler immediately so the system
    /// watchdog doesn't kill the app.
    @MainActor
    static func dispatchSystemCompletionHandler(
        for identifier: String,
        _ handler: @escaping () -> Void
    ) -> Bool {
        for downloader in all where downloader.instanceSessionID == identifier {
            downloader.storeSystemCompletionHandler(handler)
            return true
        }
        return false
    }
}
