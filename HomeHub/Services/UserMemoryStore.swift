import Foundation
import SwiftUI

/// A *small, user-curated* second memory layer that sits alongside the
/// existing `MemoryService` (`MemoryFact` / `MemoryEpisode`).
///
/// ## Why two memory layers?
/// `MemoryService` holds rich, categorised facts the LLM extracts and the
/// user later approves. It's disk-backed via the `Store` abstraction,
/// supports confidence scores, and runs through NLTagger + embedding
/// retrieval. Useful, but heavier than most "remind the assistant I
/// prefer metric units" needs.
///
/// `UserMemory` is the opposite: four plain fields the user types
/// themselves in Settings, persisted in `UserDefaults` as JSON under a
/// single key. Injected verbatim into the system prompt's context rail
/// so even small models see it on every turn, regardless of retrieval
/// heuristics.
///
/// ## Shape
/// - `name`        — how the assistant should address the user.
/// - `location`    — city / region hint (complements `AppSettings.locationHint`).
/// - `notes`       — freeform bullet list ("I'm vegetarian", "I use metric units").
/// - `preferences` — key/value pairs ("units" → "metric", "currency" → "CZK").
///
/// Kept intentionally simple — no categories, no scores, no embeddings.
/// If the user wants that, they use the richer memory pipeline.
struct UserMemory: Codable, Equatable {
    var name: String
    var location: String
    var notes: [String]
    var preferences: [UserMemoryPreference]

    static let empty = UserMemory(name: "", location: "", notes: [], preferences: [])

    /// `true` when any field carries user content — drives whether the
    /// prompt-rail injection happens at all.
    var hasContent: Bool {
        !name.isEmpty || !location.isEmpty || !notes.isEmpty || !preferences.isEmpty
    }
}

/// Single key/value entry. Kept as a struct with stable `id` so SwiftUI
/// lists can identify rows across edits without falling back to index
/// bindings (which mis-behave on delete).
struct UserMemoryPreference: Codable, Equatable, Identifiable {
    var id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

/// ObservableObject facade around `UserDefaults` persistence for
/// `UserMemory`. Designed to be injected as an `EnvironmentObject` so
/// views can bind directly without plumbing through the bigger
/// `SettingsService`.
@MainActor
final class UserMemoryStore: ObservableObject {
    @Published private(set) var memory: UserMemory

    private let defaults: UserDefaults
    private let key: String

    /// Set when stored data existed but could not be decoded.
    ///
    /// Purely diagnostic — the actual protection is the quarantine copy taken
    /// in `init`, which survives regardless of what happens to the live key.
    /// This latch just lets `persist()` log the transition from "we lost your
    /// memory" to "you re-entered it", so the Console trail explains itself.
    private var loadFailed = false

    /// Suffix for the quarantine copy taken when a decode fails.
    private static let quarantineSuffix = ".corrupt"

    init(defaults: UserDefaults = .standard, key: String = "homehub.userMemory.v1") {
        self.defaults = defaults
        self.key = key

        guard let data = defaults.data(forKey: key) else {
            // Genuinely nothing stored — first launch. Not a failure.
            self.memory = .empty
            return
        }

        do {
            self.memory = try JSONDecoder().decode(UserMemory.self, from: data)
        } catch {
            // Previously this was `try?` falling through to `.empty` with no
            // log, no backup and no signal. Because `memory` is injected into
            // every system prompt via `promptBlock()`, the visible symptom was
            // the assistant abruptly forgetting the user's name, location,
            // notes and preferences — and the very next `persist()` overwrote
            // the undecodable blob, destroying any chance of recovery.
            //
            // Now: keep a quarantine copy, refuse to overwrite the original,
            // and say so loudly. A future decoder or migration can still get
            // the data back.
            self.memory = .empty
            self.loadFailed = true
            // Only quarantine once. A second failed launch must not overwrite
            // the first (good) quarantine copy with whatever is stored now.
            if defaults.data(forKey: key + Self.quarantineSuffix) == nil {
                defaults.set(data, forKey: key + Self.quarantineSuffix)
            }
            HHLog.memory.error("""
            UserMemory decode failed (\(data.count, privacy: .public) bytes): \
            \(error.localizedDescription, privacy: .public). Starting empty; the original \
            bytes are preserved under key "\(key + Self.quarantineSuffix, privacy: .public)" \
            so a future decoder or migration can recover them.
            """)
        }
    }

    /// Clear the failed-load latch after the user has deliberately re-entered
    /// their memory, re-enabling persistence.
    ///
    /// Without this, a store that failed to decode once would never write again
    /// for the lifetime of the install. Any explicit user edit is unambiguous
    /// intent to replace whatever was there, so the mutation helpers call this.
    private func clearLoadFailureLatch() {
        guard loadFailed else { return }
        loadFailed = false
        HHLog.memory.notice("UserMemory: user edited memory after a failed load — resuming persistence")
    }

    // MARK: - Mutations

    func update(_ new: UserMemory) {
        memory = new
        persist()
    }

    func addNote(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        memory.notes.append(trimmed)
        persist()
    }

    func removeNote(at index: Int) {
        guard memory.notes.indices.contains(index) else { return }
        memory.notes.remove(at: index)
        persist()
    }

    func upsertPreference(key: String, value: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }

        if let idx = memory.preferences.firstIndex(where: { $0.key.caseInsensitiveCompare(k) == .orderedSame }) {
            memory.preferences[idx].value = v
        } else {
            memory.preferences.append(UserMemoryPreference(key: k, value: v))
        }
        persist()
    }

    func removePreference(id: UUID) {
        memory.preferences.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        memory = .empty
        persist()
    }

    // MARK: - Search
    //
    // Why: the MemoryService retriever is scored + embedding-aware for a
    // hundreds-of-items store. For the tiny, user-typed `UserMemory`
    // surface, a case-insensitive substring scan across every field is
    // both simpler and correct — any match surfaces, no ranking needed.

    func search(query: String) -> [String] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return [] }

        var hits: [String] = []
        if memory.name.lowercased().contains(needle)     { hits.append("Name: \(memory.name)") }
        if memory.location.lowercased().contains(needle) { hits.append("Location: \(memory.location)") }
        for note in memory.notes where note.lowercased().contains(needle) {
            hits.append("Note: \(note)")
        }
        for pref in memory.preferences where
            pref.key.lowercased().contains(needle) ||
            pref.value.lowercased().contains(needle)
        {
            hits.append("\(pref.key): \(pref.value)")
        }
        return hits
    }

    // MARK: - Prompt injection
    //
    // The context-rail wants a compact block, not a multi-paragraph dump.
    // `promptBlock` returns nil when `memory.hasContent` is false so the
    // prompt assembler can skip the "About you" section entirely on
    // first-run installs.

    func promptBlock() -> String? {
        guard memory.hasContent else { return nil }

        var lines: [String] = ["About you (from your saved memory):"]
        if !memory.name.isEmpty {
            lines.append("- Name: \(memory.name)")
        }
        if !memory.location.isEmpty {
            lines.append("- Location: \(memory.location)")
        }
        if !memory.notes.isEmpty {
            for note in memory.notes.prefix(12) {
                lines.append("- \(note)")
            }
        }
        if !memory.preferences.isEmpty {
            for pref in memory.preferences.prefix(12) {
                lines.append("- \(pref.key): \(pref.value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Internals

    private func persist() {
        // Any call to persist() originates from a user-initiated mutation, so
        // it is unambiguous intent to replace what was stored. Releasing the
        // latch here keeps a single failed decode from permanently disabling
        // persistence for the rest of the install.
        clearLoadFailureLatch()
        do {
            let data = try JSONEncoder().encode(memory)
            defaults.set(data, forKey: key)
        } catch {
            HHLog.settings.error("failed to persist UserMemory: \(error.localizedDescription)")
        }
    }
}
