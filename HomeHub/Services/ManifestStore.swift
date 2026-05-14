import Foundation
import os

/// Generic atomic-JSON manifest store backed by a file in Application Support.
///
/// ## Responsibilities
/// - Encode/decode a `Codable` value to/from a JSON file.
/// - Write atomically via `Data.write(to:options:.atomic)` so a mid-write
///   crash leaves the previous file intact.
/// - Create intermediate directories automatically.
///
/// ## Thread-safety
/// `ManifestStore` itself is **not** thread-safe. Callers are responsible for
/// serialising access — e.g. via a `DispatchQueue` (download coordinators) or
/// `@MainActor` (RuntimeManager). Only the file-system layer is atomic.
///
/// ## Usage
/// ```swift
/// let store = ManifestStore<MyManifest>.appSupport(filename: "my-manifest.json")
/// store.save(manifest)           // atomic write
/// let restored = store.load()    // returns nil on missing / decode failure
/// ```
struct ManifestStore<T: Codable> {

    let url: URL
    private let log = Logger(subsystem: "com.homehub.app", category: "ManifestStore")

    // MARK: - Read

    /// Decodes and returns the stored manifest, or `nil` if the file is missing
    /// or cannot be decoded. Decode errors are logged at the `.error` level.
    func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.error("ManifestStore(\(url.lastPathComponent, privacy: .public)): decode failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Write

    /// Encodes `value` and atomically writes it to `url`, creating intermediate
    /// directories as needed. Write errors are logged; they are non-fatal because
    /// the coordinator still works in-memory — only relaunch-recovery is affected.
    func save(_ value: T) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("ManifestStore(\(url.lastPathComponent, privacy: .public)): write failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Delete

    /// Removes the manifest file. Silently ignores errors (file may not exist).
    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Factory

extension ManifestStore {

    /// Returns a `ManifestStore` whose file lives at
    /// `<Application Support>/HomeHub/<filename>`.
    static func appSupport(filename: String) -> ManifestStore<T> {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = appSupport
            .appendingPathComponent("HomeHub")
            .appendingPathComponent(filename)
        return ManifestStore(url: url)
    }
}
