import Foundation
import EventKit

struct RemindersSkill: Skill {
    let name = "RemindersSearch"
    let description = "Čte a vytváří připomínky z Apple Připomínek. Vstupy: 'list' (vypíše nesplněné připomínky), nebo JSON pro vytvoření nové: {\"title\": \"Koupit mléko\", \"dueDate\": \"2024-05-20\", \"list\": \"Nákupy\"}."
    
    func execute(input: String) async throws -> String {
        let store = EKEventStore()
        
        // Request permission
        var hasAccess = false
        if #available(iOS 17.0, *) {
            hasAccess = try await store.requestFullAccessToReminders()
        } else {
            hasAccess = try await store.requestAccess(to: .reminder)
        }
        
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
        
        let reminders = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { result in
                continuation.resume(returning: result ?? [])
            }
        }
        
        guard !reminders.isEmpty else {
            return "Žádné nesplněné připomínky."
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        var lines: [String] = ["Nesplněné připomínky (\(reminders.count)):"]
        for reminder in reminders.prefix(15) {
            var line = "- \(reminder.title ?? "Bez názvu")"
            if let dueDate = reminder.dueDateComponents?.date {
                line += " (do: \(dateFormatter.string(from: dueDate)))"
            }
            if let calendar = reminder.calendar {
                line += " [\(calendar.title)]"
            }
            lines.append(line)
        }
        
        if reminders.count > 15 {
            lines.append("... a dalších \(reminders.count - 15) připomínek")
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
