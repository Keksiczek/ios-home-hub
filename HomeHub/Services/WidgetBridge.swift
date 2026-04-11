import Foundation
import WidgetKit

/// Bridges the main app's data to the Widget Extension.
///
/// Writes a compact JSON summary to the shared App Group container
/// whenever new data arrives. The widget's TimelineProvider reads
/// this file to populate its UI without importing the full app stack.
///
/// Call `WidgetBridge.shared.updateWidget(...)` after conversation
/// turns, memory changes, or on app foreground.
enum WidgetBridge {

    private static let appGroupID = "group.com.homehub.shared"
    private static let fileName = "widget-summary.json"

    struct WidgetMemoryFact: Codable {
        let content: String
        let category: String
        let pinned: Bool
    }

    struct WidgetDaySummary: Codable {
        let totalFacts: Int
        let totalConversations: Int
        let lastAssistantMessage: String?
        let topFacts: [WidgetMemoryFact]
        let updatedAt: Date
    }

    /// Writes the current app state summary so the widget can display it.
    @MainActor
    static func updateWidget(
        facts: [MemoryFact],
        conversations: [Conversation],
        lastAssistantMessage: String?
    ) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }

        let topFacts = facts
            .filter { !$0.disabled }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return a.createdAt > b.createdAt
            }
            .prefix(5)
            .map { WidgetMemoryFact(content: $0.content, category: $0.category.rawValue, pinned: $0.pinned) }

        let summary = WidgetDaySummary(
            totalFacts: facts.filter { !$0.disabled }.count,
            totalConversations: conversations.count,
            lastAssistantMessage: lastAssistantMessage,
            topFacts: Array(topFacts),
            updatedAt: .now
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let fileURL = containerURL.appendingPathComponent(fileName)
        if let data = try? encoder.encode(summary) {
            try? data.write(to: fileURL, options: .atomic)
        }

        // Tell WidgetKit to reload timelines
        WidgetCenter.shared.reloadAllTimelines()
    }
}
