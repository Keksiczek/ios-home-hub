import Foundation
import SwiftUI

struct AppSettings: Codable, Equatable {
    var memoryEnabled: Bool
    var autoExtractMemory: Bool
    var streamingEnabled: Bool
    var maxResponseTokens: Int
    var temperature: Double
    var topP: Double
    /// Top-K cutoff for sampling; `0` disables it. Default 40.
    var topK: Int
    /// Minimum-probability cutoff (`minP × p_max`); `0` disables. Default 0.05.
    var minP: Double
    /// Repeat penalty over the last `repeatPenaltyLastN` tokens; `1.0`
    /// disables it. Default 1.1 — the single biggest fix for repetition
    /// loops on small (≤ 4B) on-device models.
    var repeatPenalty: Double
    /// Window size for the repeat penalty.
    var repeatPenaltyLastN: Int
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

    /// Preferred assistant language. `.auto` follows `Locale.current`
    /// and falls back to English for unsupported locales.
    var language: AppLanguage
    /// How long the assistant's answers should be. Selects the length
    /// block that `PromptBuilder` injects into every chat turn. Kept
    /// separate from `UserProfile.preferredResponseStyle` (which shapes
    /// *tone*, not length) so the user can tweak one without disturbing
    /// the other.
    var answerLength: AnswerLength
    /// Names of skills the user has enabled. The SkillManager uses this as
    /// an allow-list both when rendering L4 tool instructions and when
    /// dispatching a parsed tool call, so a disabled skill can neither be
    /// advertised nor silently invoked.
    var enabledTools: Set<String>
    /// Optional location hint injected into the system prompt. Defaults
    /// to Nymburk, CZ for the current user; blank disables the line.
    var locationHint: String
    /// Configuration for which safety guardrails are active in prompt assembly.
    var guardrailsConfig: GuardrailsConfig
    /// Maximum seconds a single generation may run before it is cancelled and
    /// marked as failed. Covers the entire agentic-loop duration, not just a
    /// single model pass. Default: 120 s.
    var generationTimeoutSeconds: Int

    /// Trade-off between memory headroom and freedom to load larger models.
    /// Drives `RuntimeManager.memorySafetyFactor(for:)` on the next load.
    /// See `PerformanceProfile` for the exact factor mapping.
    var performanceProfile: PerformanceProfile

    static let `default` = AppSettings(
        memoryEnabled: true,
        autoExtractMemory: true,
        streamingEnabled: true,
        maxResponseTokens: 768,
        temperature: 0.7,
        topP: 0.9,
        topK: 40,
        minP: 0.05,
        repeatPenalty: 1.1,
        repeatPenaltyLastN: 64,
        haptics: true,
        theme: .system,
        selectedModelID: nil,
        systemPromptPresets: [.defaultBuiltIn],
        activeSystemPromptPresetID: SystemPromptPreset.defaultBuiltInID,
        showTokenUsage: false,
        language: .auto,
        answerLength: .balanced,
        enabledTools: AppSettings.defaultEnabledTools,
        locationHint: "Nymburk, CZ",
        guardrailsConfig: .default,
        generationTimeoutSeconds: 120,
        performanceProfile: .balanced
    )

    /// Tools registered in `SkillManager` by default. Kept in sync with
    /// `SkillManager.init` — order doesn't matter; the set is an allow-list.
    static let defaultEnabledTools: Set<String> = [
        "Calculator", "Calendar", "HomeKit", "Reminders", "DeviceInfo"
    ]

    // MARK: - Codable (migration-safe)
    //
    // Older installs persist a settings.json without the new fields.
    // `decodeIfPresent` with defaults keeps those installs working
    // without a destructive reset.

    private enum CodingKeys: String, CodingKey {
        case memoryEnabled, autoExtractMemory, streamingEnabled
        case maxResponseTokens, temperature, topP, haptics, theme
        case topK, minP, repeatPenalty, repeatPenaltyLastN
        case selectedModelID
        case systemPromptPresets, activeSystemPromptPresetID
        case showTokenUsage
        case language, answerLength, enabledTools, locationHint
        case guardrailsConfig
        case generationTimeoutSeconds
        case performanceProfile
        // Retained only for migration from the previous schema.
        case responseStyle
    }

    init(
        memoryEnabled: Bool,
        autoExtractMemory: Bool,
        streamingEnabled: Bool,
        maxResponseTokens: Int,
        temperature: Double,
        topP: Double,
        topK: Int = 40,
        minP: Double = 0.05,
        repeatPenalty: Double = 1.1,
        repeatPenaltyLastN: Int = 64,
        haptics: Bool,
        theme: AppTheme,
        selectedModelID: String?,
        systemPromptPresets: [SystemPromptPreset],
        activeSystemPromptPresetID: UUID,
        showTokenUsage: Bool,
        language: AppLanguage,
        answerLength: AnswerLength,
        enabledTools: Set<String>,
        locationHint: String,
        guardrailsConfig: GuardrailsConfig = .default,
        generationTimeoutSeconds: Int = 120,
        performanceProfile: PerformanceProfile = .balanced
    ) {
        self.memoryEnabled = memoryEnabled
        self.autoExtractMemory = autoExtractMemory
        self.streamingEnabled = streamingEnabled
        self.maxResponseTokens = maxResponseTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.repeatPenaltyLastN = repeatPenaltyLastN
        self.haptics = haptics
        self.theme = theme
        self.selectedModelID = selectedModelID
        self.systemPromptPresets = systemPromptPresets
        self.activeSystemPromptPresetID = activeSystemPromptPresetID
        self.showTokenUsage = showTokenUsage
        self.language = language
        self.answerLength = answerLength
        self.enabledTools = enabledTools
        self.locationHint = locationHint
        self.guardrailsConfig = guardrailsConfig
        self.generationTimeoutSeconds = generationTimeoutSeconds
        self.performanceProfile = performanceProfile
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
        self.topK               = try c.decodeIfPresent(Int.self,     forKey: .topK)               ?? fallback.topK
        self.minP               = try c.decodeIfPresent(Double.self,  forKey: .minP)               ?? fallback.minP
        self.repeatPenalty      = try c.decodeIfPresent(Double.self,  forKey: .repeatPenalty)      ?? fallback.repeatPenalty
        self.repeatPenaltyLastN = try c.decodeIfPresent(Int.self,     forKey: .repeatPenaltyLastN) ?? fallback.repeatPenaltyLastN
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

        self.language         = try c.decodeIfPresent(AppLanguage.self,   forKey: .language)         ?? fallback.language
        self.enabledTools     = try c.decodeIfPresent(Set<String>.self,   forKey: .enabledTools)     ?? fallback.enabledTools
        self.locationHint     = try c.decodeIfPresent(String.self,        forKey: .locationHint)     ?? fallback.locationHint
        self.guardrailsConfig = try c.decodeIfPresent(GuardrailsConfig.self, forKey: .guardrailsConfig) ?? fallback.guardrailsConfig
        self.generationTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .generationTimeoutSeconds) ?? fallback.generationTimeoutSeconds
        self.performanceProfile = try c.decodeIfPresent(PerformanceProfile.self, forKey: .performanceProfile) ?? fallback.performanceProfile

        // Migration path for installs that persisted the previous
        // `responseStyle: "leanCI" | "casual"` field. Map leanCI→concise
        // and casual→balanced so the user's intent survives the rename.
        if let decoded = try c.decodeIfPresent(AnswerLength.self, forKey: .answerLength) {
            self.answerLength = decoded
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .responseStyle) {
            switch legacy {
            case "leanCI": self.answerLength = .concise
            case "casual": self.answerLength = .balanced
            default:       self.answerLength = fallback.answerLength
            }
        } else {
            self.answerLength = fallback.answerLength
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(memoryEnabled, forKey: .memoryEnabled)
        try c.encode(autoExtractMemory, forKey: .autoExtractMemory)
        try c.encode(streamingEnabled, forKey: .streamingEnabled)
        try c.encode(maxResponseTokens, forKey: .maxResponseTokens)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(topP, forKey: .topP)
        try c.encode(topK, forKey: .topK)
        try c.encode(minP, forKey: .minP)
        try c.encode(repeatPenalty, forKey: .repeatPenalty)
        try c.encode(repeatPenaltyLastN, forKey: .repeatPenaltyLastN)
        try c.encode(haptics, forKey: .haptics)
        try c.encode(theme, forKey: .theme)
        try c.encodeIfPresent(selectedModelID, forKey: .selectedModelID)
        try c.encode(systemPromptPresets, forKey: .systemPromptPresets)
        try c.encode(activeSystemPromptPresetID, forKey: .activeSystemPromptPresetID)
        try c.encode(showTokenUsage, forKey: .showTokenUsage)
        try c.encode(language, forKey: .language)
        try c.encode(answerLength, forKey: .answerLength)
        try c.encode(enabledTools, forKey: .enabledTools)
        try c.encode(locationHint, forKey: .locationHint)
        try c.encode(guardrailsConfig, forKey: .guardrailsConfig)
        try c.encode(generationTimeoutSeconds, forKey: .generationTimeoutSeconds)
        try c.encode(performanceProfile, forKey: .performanceProfile)
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

/// Hard language selector for assistant output. Resolved once per turn
/// by `PromptBuilder` into a concrete BCP-47 tag plus a matching
/// imperative sentence for the system prompt.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case auto
    case cs
    case en

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automatic (system)"
        case .cs:   return "Čeština"
        case .en:   return "English"
        }
    }

    /// Resolves `.auto` against the supplied locale. Only `cs`/`en` are
    /// supported today; every other system language falls back to English
    /// so the prompt stays deterministic.
    func resolved(locale: Locale = .current) -> AppLanguage {
        switch self {
        case .cs, .en: return self
        case .auto:
            let code = locale.language.languageCode?.identifier.lowercased() ?? "en"
            return code == "cs" ? .cs : .en
        }
    }
}

/// How much the assistant should write per turn. Length is orthogonal
/// to tone (`UserProfile.preferredResponseStyle`) — an "analytical" tone
/// can still be concise, and a "warm" tone can still be detailed.
enum AnswerLength: String, Codable, CaseIterable, Identifiable {
    case concise
    case balanced
    case detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .concise:  return "Concise"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }

    var blurb: String {
        switch self {
        case .concise:  return "1–3 sentences. No preamble."
        case .balanced: return "A short answer with a line or two of supporting detail."
        case .detailed: return "Full answer with headings and examples where useful."
        }
    }
}

/// Memory-pressure ↔ headroom trade-off chosen by the user. Mapped to a
/// `memorySafetyFactor` inside `RuntimeManager.memorySafetyFactor(for:)`.
///
/// The current safe values are:
///   - `.conservative` → 1.8× model size required free (rejects more, OOMs less)
///   - `.balanced`     → 1.5× (the historical default)
///   - `.aggressive`   → 1.3× (accepts more loads, leaves less headroom)
///
/// The factor is consulted on every load attempt and logged, so flipping the
/// profile is observable in `DeveloperDiagnostics` without a restart.
enum PerformanceProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case conservative
    case balanced
    case aggressive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .conservative: return "Conservative"
        case .balanced:     return "Balanced"
        case .aggressive:   return "Aggressive"
        }
    }

    var blurb: String {
        switch self {
        case .conservative: return "Strict memory headroom. Rejects loads that might OOM. Best on older / 4 GB devices."
        case .balanced:     return "Default. 1.5× headroom over weights — same as previous builds."
        case .aggressive:   return "Accept tight loads. Try this only on iPhone 16 Pro / M-series iPad."
        }
    }
}
