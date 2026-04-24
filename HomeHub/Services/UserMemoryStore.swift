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

    init(defaults: UserDefaults = .standard, key: String = "homehub.userMemory.v1") {
        self.defaults = defaults
        self.key = key
        if
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(UserMemory.self, from: data)
        {
            self.memory = decoded
        } else {
            self.memory = .empty
        }
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
        do {
            let data = try JSONEncoder().encode(memory)
            defaults.set(data, forKey: key)
        } catch {
            HHLog.settings.error("failed to persist UserMemory: \(error.localizedDescription)")
        }
    }
}
