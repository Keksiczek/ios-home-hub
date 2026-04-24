import Foundation
import EventKit

struct CalendarSkill: Skill {
    let name = "CalendarSearch"
    let description = "Queries Apple Calendar for today's or tomorrow's events. Valid inputs: 'today', 'tomorrow', or a specific date like '2024-05-20'."

    /// Reports whether EventKit access is actually granted. The old code
    /// asked for permission lazily on first execution, which meant the
    /// model could emit a tool call and receive a generic "permission
    /// denied" observation — confusing both the user and the LLM. We
    /// now surface `.permission` up-front so the UI can show a "Grant
    /// calendar access" button instead.
    var availability: SkillAvailability {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return .enabled
        case .notDetermined:
            return .permission(prompt: "Calendar")
        case .denied, .restricted:
            return .permission(prompt: "Calendar (open iOS Settings to grant)")
        @unknown default:
            return .permission(prompt: "Calendar")
        }
    }

    func execute(input: String) async throws -> String {
        let store = EKEventStore()
        
        // Request permission on first use (in iOS 17 uses requestFullAccessToEvents)
        var hasAccess = false
        if #available(iOS 17.0, *) {
            hasAccess = try await store.requestFullAccessToEvents()
        } else {
            hasAccess = try await store.requestAccess(to: .event)
        }
        
        guard hasAccess else {
            return "Chyba: Uživatel nepovolil přístup ke kalendáři."
        }
        
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        
        var targetDate = Date()
        let cleanInput = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanInput == "tomorrow" {
            targetDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        } else if cleanInput != "today", let specificDate = parser.date(from: cleanInput) {
            targetDate = specificDate
        }
        
        let startOfDay = Calendar.current.startOfDay(for: targetDate)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        
        // Exclude completely remote calendars to avoid spamming the prompt?
        // Let's just fetch default events.
        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        
        guard !events.isEmpty else {
            return "Žádné události nenalezeny pro den: \(parser.string(from: targetDate))"
        }
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        
        var lines: [String] = []
        for e in events {
            let start = timeFormatter.string(from: e.startDate)
            let end = timeFormatter.string(from: e.endDate)
            lines.append("- [\(start) - \(end)] \(e.title ?? "Bez názvu")")
        }
        
        return lines.joined(separator: "\n")
    }
}
