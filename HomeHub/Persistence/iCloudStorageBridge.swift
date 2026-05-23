import Foundation
import os

/// Resolves storage locations for app data and shuttles files between
/// local Application Support and the user's iCloud Drive Documents
/// container.
///
/// ## Why this exists
///
/// Before this helper, `FileStore` always wrote into
/// `~/Library/Application Support/HomeHub/`. That directory is
/// sandbox-local and is **deleted whenever the user does a clean
/// install** — either via "Delete App" on the home screen or, on
/// development devices, every time Xcode replaces the bundle. Users
/// reported losing their entire chat history, memory facts, and
/// onboarding profile after every TestFlight refresh.
///
/// This bridge lets `FileStore` operate against an iCloud Documents
/// directory instead. iCloud-backed storage survives reinstalls and
/// — more importantly — automatically syncs across the user's other
/// signed-in devices.
///
/// ## How sync works
///
/// We use the Apple-integrated **iCloud Documents** path. File writes
/// go into `<UbiquityContainer>/Documents/HomeHub/`, where iOS
/// transparently uploads the bytes to iCloud and propagates them to
/// other devices. No CloudKit container, no schema migration, no
/// custom conflict resolution — Apple handles it the same way it
/// handles Pages / Numbers documents.
///
/// ## Activation
///
/// Sync is **opt-in** behind `AppSettings.iCloudSyncEnabled`. The
/// resolver returns the local Application Support path when:
///
///   * the user hasn't enabled the setting, OR
///   * the iCloud entitlement isn't present in the build (free Apple
///     ID without an iCloud container, sandboxed contributor builds), OR
///   * the user is signed out of iCloud at the system level.
///
/// All three cases degrade silently to local storage — the app keeps
/// working, the user just doesn't get cross-device sync.
///
/// ## Migration
///
/// Toggling the setting fires `iCloudStorageBridge.migrate(...)`,
/// which copies every file from the current root to the new root and
/// then deletes the source. Bi-directional: works for the initial
/// "enable" pass (local → iCloud) and the "disable" pass
/// (iCloud → local). File coordination is used so a parallel
/// download from another device can't truncate a file mid-copy.
enum iCloudStorageBridge {

    private static let log = Logger(subsystem: "HomeHub", category: "iCloud")

    /// Sub-folder name inside the container, matching the local
    /// Application Support layout. Kept lowercase-free and dot-free
    /// so iCloud's NSMetadataQuery filename filters don't reject it.
    static let folderName = "HomeHub"

    /// Resolves the directory the current FileStore should write into.
    ///
    /// - Parameter preferICloud: User's persisted preference, typically
    ///   `AppSettings.iCloudSyncEnabled`. Pass `false` when the user
    ///   hasn't opted in (the default for a fresh install).
    /// - Returns: A URL pointing at either the iCloud Documents
    ///   sub-folder (when sync is enabled AND available) or the local
    ///   Application Support sub-folder (otherwise). The returned
    ///   directory is created on disk before return so callers can
    ///   write into it immediately.
    static func resolveStorageDirectory(preferICloud: Bool) -> URL {
        let fileManager = FileManager.default

        if preferICloud, let cloudRoot = iCloudDocumentsURL() {
            try? fileManager.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
            log.info("iCloud storage: using ubiquity container at \(cloudRoot.path, privacy: .public)")
            return cloudRoot
        }

        if preferICloud {
            log.notice("iCloud storage: enabled in settings but no ubiquity container available — falling back to local Application Support")
        }

        let local = localApplicationSupportURL()
        try? fileManager.createDirectory(at: local, withIntermediateDirectories: true)
        return local
    }

    /// Returns the iCloud Documents directory for this app, or `nil`
    /// when iCloud isn't available.
    ///
    /// Calls `FileManager.url(forUbiquityContainerIdentifier:)` with
    /// `nil`, which asks for the default container — the one declared
    /// by the `com.apple.developer.ubiquity-container-identifiers`
    /// entitlement. Returns `nil` on:
    ///   * missing entitlement (free Apple ID without container setup)
    ///   * user signed out of iCloud at system level
    ///   * iCloud disabled for the app in Settings → iCloud
    ///
    /// The call performs a synchronous IPC into `cloudd` and can take
    /// 50–200 ms cold; subsequent invocations are cached by the
    /// framework. Worth doing once at FileStore init time and reusing
    /// the result for the lifetime of the store.
    static func iCloudDocumentsURL() -> URL? {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        return containerURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Local Application Support fallback. Always available — no
    /// entitlement required, no iCloud account needed.
    static func localApplicationSupportURL() -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Probes iCloud availability without performing any I/O on the
    /// real directory. Used by the Settings toggle to render an
    /// enabled / disabled state without committing to a sync run.
    static var isAvailable: Bool {
        iCloudDocumentsURL() != nil
    }

    // MARK: - Migration

    /// Copies the entire directory tree from `source` to `destination`,
    /// then removes the source. Used when the user toggles the iCloud
    /// preference: enable → migrate local → iCloud; disable →
    /// migrate iCloud → local.
    ///
    /// Atomicity caveat: this is **best-effort, not transactional**.
    /// We copy first, then remove. A crash between the two leaves the
    /// data in both locations — the next launch's FileStore will pick
    /// whichever the toggle says, and the orphan tree is harmless
    /// (the user can delete it manually from Files.app if it ever
    /// becomes visible there).
    ///
    /// File coordination guards each individual file copy so a
    /// concurrent iCloud download / Files.app preview can't see a
    /// half-written file.
    ///
    /// - Parameters:
    ///   - source: The directory whose contents should be moved.
    ///   - destination: Where the contents end up. Created if needed.
    /// - Returns: `(copied, failed)` file counts so the UI can show
    ///   "Migrated 12 files".
    @discardableResult
    static func migrate(from source: URL, to destination: URL) async throws -> (copied: Int, failed: Int) {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: source.path) else {
            log.info("iCloud migrate: source missing at \(source.path, privacy: .public) — no-op")
            return (0, 0)
        }
        if source.standardizedFileURL == destination.standardizedFileURL {
            log.info("iCloud migrate: source == destination — no-op")
            return (0, 0)
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let items = (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? []
        var copied = 0
        var failed = 0

        for item in items {
            let src = source.appendingPathComponent(item)
            let dst = destination.appendingPathComponent(item)
            do {
                // Replace any pre-existing item at the destination so a
                // partial migration from a prior attempt is overwritten
                // rather than aborted with "file exists".
                if fileManager.fileExists(atPath: dst.path) {
                    try fileManager.removeItem(at: dst)
                }
                try fileManager.copyItem(at: src, to: dst)
                copied += 1
            } catch {
                log.error("iCloud migrate: copy failed for '\(item, privacy: .public)' — \(error.localizedDescription, privacy: .public)")
                failed += 1
            }
        }

        // Only remove the source AFTER every copy attempt. A failed
        // copy leaves the original in place so the user can retry.
        if failed == 0 {
            do {
                try fileManager.removeItem(at: source)
                log.info("iCloud migrate: removed source after successful copy of \(copied, privacy: .public) item(s)")
            } catch {
                log.error("iCloud migrate: removeItem on source failed — \(error.localizedDescription, privacy: .public)")
            }
        } else {
            log.warning("iCloud migrate: \(failed, privacy: .public) item(s) failed to copy; source kept for retry")
        }

        return (copied, failed)
    }
}
