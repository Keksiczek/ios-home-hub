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

    private static let appGroupID = "group.cz.keksiczek.homehub.shared"
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
    ///
    /// ## Concurrency
    /// Public API stays `@MainActor` because callers pass
    /// `MemoryFact` / `Conversation` arrays observed from main-actor
    /// state. The actual disk read + write + encode is moved into a
    /// `Task.detached(priority: .utility)` so a high-frequency caller
    /// (e.g. every conversation turn) doesn't block the main thread
    /// on container IO. `WidgetCenter.reloadAllTimelines()` stays on
    /// main — it's a fast notification call, not the IO.
    @MainActor
    static func updateWidget(
        facts: [MemoryFact]? = nil,
        conversations: [Conversation]? = nil,
        lastAssistantMessage: String? = nil,
        keepLastMessage: Bool = false
    ) {
        // Pre-compute the top-facts projection on the main actor
        // (cheap, in-memory). The disk read + encode + write run
        // off main below.
        let topFactsProjection: [WidgetMemoryFact]? = facts.map { facts in
            facts
                .filter { !$0.disabled }
                .sorted { a, b in
                    if a.pinned != b.pinned { return a.pinned }
                    return a.createdAt > b.createdAt
                }
                .prefix(5)
                .map { WidgetMemoryFact(
                    content: $0.content,
                    category: $0.category.rawValue,
                    pinned: $0.pinned
                ) }
        }
        let totalFacts = facts.map { $0.filter { !$0.disabled }.count }
        let totalConversations = conversations?.count

        Task.detached(priority: .utility) {
            persistSummary(
                topFactsProjection: topFactsProjection,
                totalFacts: totalFacts,
                totalConversations: totalConversations,
                lastAssistantMessage: lastAssistantMessage,
                keepLastMessage: keepLastMessage
            )
            // Hop back to main for the WidgetKit notification —
            // `reloadAllTimelines` is documented main-thread-safe
            // but staying explicit keeps the call site obvious.
            await MainActor.run {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    /// Disk read + merge + write. Pure value-type input, runs off
    /// main. Failures are swallowed (best-effort widget refresh).
    private static func persistSummary(
        topFactsProjection: [WidgetMemoryFact]?,
        totalFacts: Int?,
        totalConversations: Int?,
        lastAssistantMessage: String?,
        keepLastMessage: Bool
    ) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }
        let fileURL = containerURL.appendingPathComponent(fileName)

        var existingTotalFacts = 0
        var existingTotalConversations = 0
        var existingLastMessage: String? = nil
        var existingTopFacts: [WidgetMemoryFact] = []
        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONDecoder().decode(WidgetDaySummary.self, from: data) {
            existingTotalFacts = existing.totalFacts
            existingTotalConversations = existing.totalConversations
            existingLastMessage = existing.lastAssistantMessage
            existingTopFacts = existing.topFacts
        }

        let summary = WidgetDaySummary(
            totalFacts: totalFacts ?? existingTotalFacts,
            totalConversations: totalConversations ?? existingTotalConversations,
            lastAssistantMessage: keepLastMessage ? existingLastMessage : lastAssistantMessage,
            topFacts: topFactsProjection ?? existingTopFacts,
            updatedAt: .now
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(summary) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
