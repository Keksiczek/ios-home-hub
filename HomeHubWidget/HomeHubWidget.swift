import WidgetKit
import SwiftUI

// MARK: - Shared Data (read from App Group container)

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

// MARK: - Timeline Provider

struct HomeHubTimelineProvider: TimelineProvider {
    typealias Entry = HomeHubWidgetEntry

    func placeholder(in context: Context) -> HomeHubWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeHubWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeHubWidgetEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh every 30 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadEntry() -> HomeHubWidgetEntry {
        // Read shared data from the App Group container.
        // The main app writes widget-summary.json after each conversation.
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.homehub.shared"
        ) else { return .placeholder }

        let fileURL = containerURL.appendingPathComponent("widget-summary.json")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return .placeholder
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let summary = try? decoder.decode(WidgetDaySummary.self, from: data) else {
            return .placeholder
        }

        return HomeHubWidgetEntry(
            date: summary.updatedAt,
            totalFacts: summary.totalFacts,
            totalConversations: summary.totalConversations,
            lastMessage: summary.lastAssistantMessage,
            topFacts: summary.topFacts,
            isPlaceholder: false
        )
    }
}

// MARK: - Timeline Entry

struct HomeHubWidgetEntry: TimelineEntry {
    let date: Date
    let totalFacts: Int
    let totalConversations: Int
    let lastMessage: String?
    let topFacts: [WidgetMemoryFact]
    let isPlaceholder: Bool

    static let placeholder = HomeHubWidgetEntry(
        date: .now,
        totalFacts: 12,
        totalConversations: 5,
        lastMessage: "Dobrý den! Jak ti mohu dnes pomoct?",
        topFacts: [
            WidgetMemoryFact(content: "Pracuji jako iOS developer", category: "work", pinned: true),
            WidgetMemoryFact(content: "Preferuji tmavý režim", category: "preferences", pinned: false),
        ],
        isPlaceholder: true
    )
}

// MARK: - Widget Views

struct HomeHubWidgetSmallView: View {
    let entry: HomeHubWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text("HomeHub")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer()

            if let msg = entry.lastMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
            }

            Spacer()

            HStack(spacing: 12) {
                Label("\(entry.totalFacts)", systemImage: "brain")
                    .font(.system(size: 11, weight: .medium))
                Label("\(entry.totalConversations)", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding()
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(hue: 0.68, saturation: 0.60, brightness: 0.40),
                    Color(hue: 0.58, saturation: 0.55, brightness: 0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

struct HomeHubWidgetMediumView: View {
    let entry: HomeHubWidgetEntry

    var body: some View {
        HStack(spacing: 12) {
            // Left: Stats + last message
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text("HomeHub")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Spacer()

                if let msg = entry.lastMessage {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 12) {
                    Label("\(entry.totalFacts) faktů", systemImage: "brain")
                    Label("\(entry.totalConversations) chatů", systemImage: "bubble.left")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            }

            Divider()
                .background(.white.opacity(0.2))

            // Right: Top Facts
            VStack(alignment: .leading, spacing: 6) {
                Text("PAMĚŤ")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(1.5)

                ForEach(entry.topFacts.prefix(3), id: \.content) { fact in
                    HStack(spacing: 4) {
                        Image(systemName: fact.pinned ? "pin.fill" : "circle.fill")
                            .font(.system(size: fact.pinned ? 8 : 4))
                            .foregroundStyle(fact.pinned ? .yellow : .white.opacity(0.5))
                        Text(fact.content)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(hue: 0.68, saturation: 0.60, brightness: 0.40),
                    Color(hue: 0.58, saturation: 0.55, brightness: 0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Lock Screen (accessoryRectangular)

struct HomeHubAccessoryView: View {
    let entry: HomeHubWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 10, weight: .bold))
                Text("HomeHub")
                    .font(.system(size: 11, weight: .bold))
            }

            if let msg = entry.lastMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .opacity(0.8)
            } else {
                Text("\(entry.totalFacts) faktů • \(entry.totalConversations) konverzací")
                    .font(.system(size: 10))
                    .opacity(0.8)
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

// MARK: - Widget Configuration

struct HomeHubWidgetEntryView: View {
    var entry: HomeHubTimelineProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HomeHubAccessoryView(entry: entry)
        case .systemMedium:
            HomeHubWidgetMediumView(entry: entry)
        case .systemSmall:
            HomeHubWidgetSmallView(entry: entry)
        default:
            HomeHubWidgetSmallView(entry: entry)
        }
    }
}

struct HomeHubWidget: Widget {
    let kind: String = "HomeHubWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HomeHubTimelineProvider()) { entry in
            HomeHubWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("HomeHub Asistent")
        .description("Rychlý přehled tvého osobního AI asistenta — paměť, chaty a poslední odpověď.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular
        ])
    }
}

// MARK: - Widget Bundle

@main
struct HomeHubWidgetBundle: WidgetBundle {
    var body: some Widget {
        HomeHubWidget()
    }
}
