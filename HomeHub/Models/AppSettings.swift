import Foundation

struct AppSettings: Codable, Equatable {
    var memoryEnabled: Bool
    var autoExtractMemory: Bool
    var streamingEnabled: Bool
    var maxResponseTokens: Int
    var temperature: Double
    var topP: Double
    var haptics: Bool
    var theme: AppTheme

    static let `default` = AppSettings(
        memoryEnabled: true,
        autoExtractMemory: true,
        streamingEnabled: true,
        maxResponseTokens: 768,
        temperature: 0.7,
        topP: 0.9,
        haptics: true,
        theme: .system
    )
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match system"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}
