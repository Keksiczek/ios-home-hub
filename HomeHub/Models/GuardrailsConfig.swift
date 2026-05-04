import Foundation

/// Configuration for which safety guardrails and prompt layers are active.
struct GuardrailsConfig: Codable, Equatable {
    // MARK: - Guardrails

    /// Include hard rules (output format, honesty, language matching, coherence)
    var hardRulesEnabled: Bool = true

    /// Include privacy guardrail (never fabricate user details, no network claims)
    var privacyGuardrailEnabled: Bool = true

    // MARK: - Prompt layers

    /// Include L1: Durable facts (user-controlled, pinned + retrieved)
    var factsEnabled: Bool = true

    /// Include L2: Episodic summaries (time-bound context)
    var episodesEnabled: Bool = true

    /// Include L3: Source excerpts from attached files
    var fileExcerptsEnabled: Bool = true

    /// Include L4: Agentic tool instructions (skill manifests)
    var skillInstructionsEnabled: Bool = true

    static let `default` = GuardrailsConfig(
        hardRulesEnabled: true,
        privacyGuardrailEnabled: true,
        factsEnabled: true,
        episodesEnabled: true,
        fileExcerptsEnabled: true,
        skillInstructionsEnabled: true
    )

    static let unrestricted = GuardrailsConfig(
        hardRulesEnabled: false,
        privacyGuardrailEnabled: false,
        factsEnabled: true,
        episodesEnabled: true,
        fileExcerptsEnabled: true,
        skillInstructionsEnabled: true
    )
}
