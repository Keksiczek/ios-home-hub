import Foundation

/// Defines a native capability that the LLM can invoke.
protocol Skill: Sendable {
    /// The exact tag name the LLM must emit to trigger this skill.
    /// e.g. "Calculator", "WebSearch"
    var name: String { get }

    /// Instructions injected into the system prompt detailing what this skill does
    /// and what the input should look like.
    var description: String { get }

    /// Current runtime availability — ready, missing permission, or
    /// entirely unavailable on this device. Defaults to `.enabled` so
    /// skills that don't need OS permissions don't have to opt in.
    var availability: SkillAvailability { get }

    /// Executes the native action with the parsed string argument.
    func execute(input: String) async throws -> String
}

extension Skill {
    /// Default implementation — most skills don't need special OS
    /// permissions (Calculator, DeviceInfo, WebSearch). Skills that
    /// do (Calendar, HomeKit, Reminders) override this.
    var availability: SkillAvailability { .enabled }
}
