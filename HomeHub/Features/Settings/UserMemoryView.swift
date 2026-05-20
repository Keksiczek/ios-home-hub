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
    @State private var showingClearConfirm: Bool = false

    var body: some View {
        Form {
            aboutYouSection
            notesSection
            preferencesSection
            dangerZone
        }
        .navigationTitle("Moje paměť")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Smazat všechnu paměť?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Smazat vše", role: .destructive) {
                store.clear()
            }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Trvale smaže jméno asistenta, všechny tvoje poznámky a každou předvolbu. Nelze vrátit zpět.")
        }
    }

    // MARK: - Sections

    private var aboutYouSection: some View {
        Section {
            TextField("Jméno, kterým tě má asistent oslovovat", text: Binding(
                get: { store.memory.name },
                set: { newValue in
                    var m = store.memory
                    m.name = newValue
                    store.update(m)
                }
            ))
            .textInputAutocapitalization(.words)

            TextField("Lokalita", text: Binding(
                get: { store.memory.location },
                set: { newValue in
                    var m = store.memory
                    m.location = newValue
                    store.update(m)
                }
            ))
            .textInputAutocapitalization(.words)
        } header: {
            Text("O tobě")
        } footer: {
            Text("Vkládá se doslova do kontextu asistenta při každé odpovědi. Zůstává jen na tomto zařízení.")
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
                            Label("Smazat", systemImage: "trash")
                        }
                    }
            }

            HStack {
                TextField("Nová poznámka (např. preferuji metrické jednotky)", text: $newNote)
                Button {
                    store.addNote(newNote)
                    newNote = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Poznámky")
        } footer: {
            Text("Krátké volné poznámky. Přejetím doleva poznámku smažeš.")
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
                        Label("Smazat", systemImage: "trash")
                    }
                }
            }

            HStack {
                TextField("Klíč", text: $newPrefKey)
                    .frame(maxWidth: 120)
                TextField("Hodnota", text: $newPrefValue)
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
            Text("Předvolby")
        } footer: {
            Text("Páry klíč–hodnota, např. units → metric, currency → CZK.")
        }
    }

    private var dangerZone: some View {
        Section {
            Button(role: .destructive) {
                showingClearConfirm = true
            } label: {
                Text("Smazat všechnu paměť")
            }
            .disabled(!store.memory.hasContent)
        }
    }
}
