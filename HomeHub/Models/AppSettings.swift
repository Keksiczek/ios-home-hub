import Foundation
import SwiftUI

struct AppSettings: Codable, Equatable {
    var memoryEnabled: Bool
    var autoExtractMemory: Bool
    var streamingEnabled: Bool
    var maxResponseTokens: Int
    var temperature: Double
    var topP: Double
    var haptics: Bool
    var theme: AppTheme
    /// ID of the last model the user loaded. Used to auto-load on
    /// app launch and after onboarding.
    var selectedModelID: String?
    /// User-managed system-prompt presets. At least one entry
    /// (the built-in `Default`) is always present.
    var systemPromptPresets: [SystemPromptPreset]
    /// Preset currently used to seed the system prompt.
    var activeSystemPromptPresetID: UUID
    /// When true, the chat screen shows an estimated token-usage
    /// badge next to the title.
    var showTokenUsage: Bool

    static let `default` = AppSettings(
        memoryEnabled: true,
        autoExtractMemory: true,
        streamingEnabled: true,
        maxResponseTokens: 768,
        temperature: 0.7,
        topP: 0.9,
        haptics: true,
        theme: .system,
        selectedModelID: nil,
        systemPromptPresets: [.defaultBuiltIn],
        activeSystemPromptPresetID: SystemPromptPreset.defaultBuiltInID,
        showTokenUsage: false
    )

    // MARK: - Codable (migration-safe)
    //
    // Older installs persist a settings.json without the preset /
    // token-usage fields. `decodeIfPresent` with defaults keeps those
    // installs working without a destructive reset.

    private enum CodingKeys: String, CodingKey {
        case memoryEnabled, autoExtractMemory, streamingEnabled
        case maxResponseTokens, temperature, topP, haptics, theme
        case selectedModelID
        case systemPromptPresets, activeSystemPromptPresetID
        case showTokenUsage
    }

    init(
        memoryEnabled: Bool,
        autoExtractMemory: Bool,
        streamingEnabled: Bool,
        maxResponseTokens: Int,
        temperature: Double,
        topP: Double,
        haptics: Bool,
        theme: AppTheme,
        selectedModelID: String?,
        systemPromptPresets: [SystemPromptPreset],
        activeSystemPromptPresetID: UUID,
        showTokenUsage: Bool
    ) {
        self.memoryEnabled = memoryEnabled
        self.autoExtractMemory = autoExtractMemory
        self.streamingEnabled = streamingEnabled
        self.maxResponseTokens = maxResponseTokens
        self.temperature = temperature
        self.topP = topP
        self.haptics = haptics
        self.theme = theme
        self.selectedModelID = selectedModelID
        self.systemPromptPresets = systemPromptPresets
        self.activeSystemPromptPresetID = activeSystemPromptPresetID
        self.showTokenUsage = showTokenUsage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default
        self.memoryEnabled      = try c.decodeIfPresent(Bool.self,    forKey: .memoryEnabled)      ?? fallback.memoryEnabled
        self.autoExtractMemory  = try c.decodeIfPresent(Bool.self,    forKey: .autoExtractMemory)  ?? fallback.autoExtractMemory
        self.streamingEnabled   = try c.decodeIfPresent(Bool.self,    forKey: .streamingEnabled)   ?? fallback.streamingEnabled
        self.maxResponseTokens  = try c.decodeIfPresent(Int.self,     forKey: .maxResponseTokens)  ?? fallback.maxResponseTokens
        self.temperature        = try c.decodeIfPresent(Double.self,  forKey: .temperature)        ?? fallback.temperature
        self.topP               = try c.decodeIfPresent(Double.self,  forKey: .topP)               ?? fallback.topP
        self.haptics            = try c.decodeIfPresent(Bool.self,    forKey: .haptics)            ?? fallback.haptics
        self.theme              = try c.decodeIfPresent(AppTheme.self, forKey: .theme)             ?? fallback.theme
        self.selectedModelID    = try c.decodeIfPresent(String.self,  forKey: .selectedModelID)

        let presets = try c.decodeIfPresent([SystemPromptPreset].self, forKey: .systemPromptPresets) ?? []
        // Always guarantee at least one built-in preset exists.
        if presets.contains(where: { $0.id == SystemPromptPreset.defaultBuiltInID }) {
            self.systemPromptPresets = presets
        } else {
            self.systemPromptPresets = [.defaultBuiltIn] + presets
        }

        let activeID = try c.decodeIfPresent(UUID.self, forKey: .activeSystemPromptPresetID) ?? SystemPromptPreset.defaultBuiltInID
        self.activeSystemPromptPresetID = self.systemPromptPresets.contains(where: { $0.id == activeID })
            ? activeID
            : SystemPromptPreset.defaultBuiltInID

        self.showTokenUsage = try c.decodeIfPresent(Bool.self, forKey: .showTokenUsage) ?? fallback.showTokenUsage
    }
}

extension AppSettings {
    /// Resolves the active preset, falling back to the built-in default
    /// if the active ID points at a preset that's since been deleted.
    var activeSystemPromptPreset: SystemPromptPreset {
        systemPromptPresets.first { $0.id == activeSystemPromptPresetID }
            ?? systemPromptPresets.first { $0.id == SystemPromptPreset.defaultBuiltInID }
            ?? .defaultBuiltIn
    }
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

    /// Maps to SwiftUI's `preferredColorScheme(_:)`.
    /// `nil` means "follow the system setting".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
