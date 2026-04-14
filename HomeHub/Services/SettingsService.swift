import Foundation
import SwiftUI

/// Publishes the current `AppSettings` and mediates every read/write
/// against the persistence `Store`.
///
/// Persistence contract (tightened after the UI refactor):
///
/// - `load()` always converges on a valid on-disk `settings.json`.
///   If the file is missing or fails to decode, the service falls
///   back to `AppSettings.default` *and* tries to seed the disk with
///   that default so subsequent launches are deterministic.
/// - `update(_:)` / `set(_:to:)` are **save-first**: the in-memory
///   `current` is only advanced after the store accepts the write.
///   A failed save leaves `current` and disk in agreement with the
///   previous value, so views never render a state the disk doesn't
///   know about.
@MainActor
final class SettingsService: ObservableObject {
    @Published private(set) var current: AppSettings = .default
    private let store: any Store

    init(store: any Store) {
        self.store = store
    }

    // MARK: - Loading

    func load() async {
        do {
            if let saved = try await store.loadAppSettings() {
                current = saved
                return
            }
            // File is simply absent — first launch or post-reset.
            Self.log("no settings file on disk; seeding defaults.")
        } catch {
            // Decode or IO error. Fall back to defaults and try to
            // overwrite the corrupted file so we don't hit this path
            // every launch.
            Self.log("load failed (\(error.localizedDescription)); recovering to defaults.")
        }
        current = .default
        await persist(.default)
    }

    // MARK: - Writes

    /// Save-first: disk is written first, in-memory state is only
    /// advanced after a successful write so memory and disk can never
    /// silently diverge.
    func update(_ settings: AppSettings) async {
        if await persist(settings) {
            current = settings
        }
    }

    func set<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>, to value: Value) async {
        var next = current
        next[keyPath: keyPath] = value
        await update(next)
    }

    // MARK: - Internals

    /// Attempts to persist `candidate` to the backing store. Returns
    /// `true` when the store accepted the write, `false` otherwise.
    /// Failures are logged but never thrown — callers decide how to
    /// react (see `update(_:)` which treats false as "don't commit").
    @discardableResult
    private func persist(_ candidate: AppSettings) async -> Bool {
        do {
            try await store.save(settings: candidate)
            return true
        } catch {
            Self.log("save failed: \(error.localizedDescription); keeping previous state.")
            return false
        }
    }

    // Centralised so there's exactly one place to swap `print` for
    // `os.Logger` later if the project grows a proper logging layer.
    private static func log(_ message: String) {
        print("[SettingsService] \(message)")
    }
}
