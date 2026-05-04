import Foundation

/// Configuration for which safety guardrails are active in the prompt assembly.
/// Allows users to disable guardrails for unrestricted output.
struct GuardrailsConfig: Codable, Equatable {
    /// Include hard rules (output format, honesty, language matching, coherence)
    var hardRulesEnabled: Bool = true

    /// Include privacy guardrail (never fabricate user details, no network claims)
    var privacyGuardrailEnabled: Bool = true

    static let `default` = GuardrailsConfig(
        hardRulesEnabled: true,
        privacyGuardrailEnabled: true
    )

    static let unrestricted = GuardrailsConfig(
        hardRulesEnabled: false,
        privacyGuardrailEnabled: false
    )
}
