import SwiftUI

/// Settings screen for the user-curated `UserMemory` layer (the
/// lightweight UserDefaults-backed memory that sits alongside the
/// retrieval-based `MemoryService`).
///
/// Split from `SettingsView` so the bindings (many, with add/remove
/// actions) don't balloon the main settings body.
struct UserMemoryView: View {
    @EnvironmentObject private var store: UserMemoryStore

    @State private var newNote: String = ""
    @State private var newPrefKey: String = ""
    @State private var newPrefValue: String = ""

    var body: some View {
        Form {
            aboutYouSection
            notesSection
            preferencesSection
            dangerZone
        }
        .navigationTitle("My memory")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var aboutYouSection: some View {
        Section {
            TextField("Name the assistant should use", text: Binding(
                get: { store.memory.name },
                set: { newValue in
                    var m = store.memory
                    m.name = newValue
                    store.update(m)
                }
            ))
            .textInputAutocapitalization(.words)

            TextField("Location", text: Binding(
                get: { store.memory.location },
                set: { newValue in
                    var m = store.memory
                    m.location = newValue
                    store.update(m)
                }
            ))
            .textInputAutocapitalization(.words)
        } header: {
            Text("About you")
        } footer: {
            Text("Injected verbatim into the assistant's context on every turn. Kept on this device only.")
        }
    }

    private var notesSection: some View {
        Section {
            ForEach(Array(store.memory.notes.enumerated()), id: \.offset) { idx, note in
                Text(note)
                    .swipeActions {
                        Button(role: .destructive) {
                            store.removeNote(at: idx)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }

            HStack {
                TextField("New note (e.g. \"I prefer metric units\")", text: $newNote)
                Button {
                    store.addNote(newNote)
                    newNote = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Notes")
        } footer: {
            Text("Short, freeform reminders. Swipe left to remove a note.")
        }
    }

    private var preferencesSection: some View {
        Section {
            ForEach(store.memory.preferences) { pref in
                HStack {
                    Text(pref.key)
                        .foregroundStyle(HHTheme.textSecondary)
                    Spacer()
                    Text(pref.value)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.removePreference(id: pref.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            HStack {
                TextField("Key", text: $newPrefKey)
                    .frame(maxWidth: 120)
                TextField("Value", text: $newPrefValue)
                Button {
                    store.upsertPreference(key: newPrefKey, value: newPrefValue)
                    newPrefKey = ""
                    newPrefValue = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newPrefKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Preferences")
        } footer: {
            Text("Key–value pairs such as units → metric, currency → CZK.")
        }
    }

    private var dangerZone: some View {
        Section {
            Button(role: .destructive) {
                store.clear()
            } label: {
                Text("Clear all memory")
            }
            .disabled(!store.memory.hasContent)
        }
    }
}
