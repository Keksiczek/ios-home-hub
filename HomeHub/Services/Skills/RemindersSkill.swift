import Foundation
import EventKit

/// Sendable snapshot of a single `EKReminder`. All properties are copied
/// synchronously inside the `fetchReminders` callback — before the
/// continuation resumes — so no `EKReminder` ever crosses a Swift 6
/// concurrency boundary.
private struct ReminderSnapshot: Sendable {
    let title: String
    let dueDate: Date?
    let calendarTitle: String?
    let count: Int // only used for the total; removed once we switch to array

    init(_ reminder: EKReminder) {
        self.title = reminder.title ?? "Bez názvu"
        self.dueDate = reminder.dueDateComponents?.date
        self.calendarTitle = reminder.calendar?.title
        self.count = 0 // unused per-item field; total is computed separately
    }
}

struct RemindersSkill: Skill {
    let name = "RemindersSearch"
    let description = "Čte a vytváří připomínky z Apple Připomínek. Vstupy: 'list' (vypíše nesplněné připomínky), nebo JSON pro vytvoření nové: {\"title\": \"Koupit mléko\", \"dueDate\": \"2024-05-20\", \"list\": \"Nákupy\"}."

    /// Reports EventKit (Reminders) authorization up-front so the
    /// agentic loop can present a "Grant permission" UI affordance
    /// instead of swallowing the failure inside an `<Observation>`.
    var availability: SkillAvailability {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return .enabled
        case .notDetermined:
            return .permission(prompt: "Reminders")
        case .denied, .restricted:
            return .permission(prompt: "Reminders (open iOS Settings to grant)")
        @unknown default:
            return .permission(prompt: "Reminders")
        }
    }

    /// Anything that is not an explicit read creates a reminder.
    ///
    /// Deliberately a deny-by-default shape: `execute` treats "list" and the
    /// empty string as reads and *everything else* as a create, so mirroring
    /// that exactly — rather than pattern-matching create-like phrasings —
    /// means a new read verb added to `execute` fails closed (over-restricting)
    /// instead of open.
    ///
    /// This is the skill with no precondition in the injection chain: once
    /// EventKit access has been granted a single time, an attacker-chosen title
    /// and date can be written with nothing else required.
    func isStateChanging(input: String) -> Bool {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !(clean == "list" || clean.isEmpty)
    }

    func execute(input: String) async throws -> String {
        let store = EKEventStore()

        let hasAccess = try await store.requestFullAccessToReminders()

        guard hasAccess else {
            return "Chyba: Uživatel nepovolil přístup k připomínkám."
        }

        let cleanInput = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if cleanInput == "list" || cleanInput.isEmpty {
            return await listIncomplete(store: store)
        } else {
            return await createReminder(from: input, store: store)
        }
    }

    private func listIncomplete(store: EKEventStore) async -> String {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )

        // Snapshot all needed data inside the callback so that no
        // non-Sendable `EKReminder` object crosses the continuation boundary.
        let (snapshots, total): ([ReminderSnapshot], Int) = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { result in
                let all = result ?? []
                let snaps = all.prefix(15).map { ReminderSnapshot($0) }
                continuation.resume(returning: (Array(snaps), all.count))
            }
        }

        guard total > 0 else {
            return "Žádné nesplněné připomínky."
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var lines: [String] = ["Nesplněné připomínky (\(total)):"]
        for snap in snapshots {
            var line = "- \(snap.title)"
            if let dueDate = snap.dueDate {
                line += " (do: \(dateFormatter.string(from: dueDate)))"
            }
            if let calendarTitle = snap.calendarTitle {
                line += " [\(calendarTitle)]"
            }
            lines.append(line)
        }

        if total > 15 {
            lines.append("... a dalších \(total - 15) připomínek")
        }

        return lines.joined(separator: "\n")
    }

    private func createReminder(from jsonString: String, store: EKEventStore) async -> String {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = dict["title"] as? String else {
            return "Chyba: Neplatný formát. Odpověz JSON: {\"title\": \"Text připomínky\", \"dueDate\": \"2024-05-20\"}"
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title

        // Optionally assign to a specific list
        if let listName = dict["list"] as? String,
           let targetCalendar = store.calendars(for: .reminder).first(where: {
               $0.title.lowercased() == listName.lowercased()
           }) {
            reminder.calendar = targetCalendar
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        // Optional due date
        if let dueDateString = dict["dueDate"] as? String {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            if let date = parser.date(from: dueDateString) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: date
                )
            }
        }

        do {
            try store.save(reminder, commit: true)
            return "Připomínka '\(title)' byla úspěšně vytvořena."
        } catch {
            return "Chyba při ukládání připomínky: \(error.localizedDescription)"
        }
    }
}
