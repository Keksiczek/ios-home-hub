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
    ///
    /// `@MainActor` because OS authorization checks (EventKit, HomeKit)
    /// are annotated @MainActor in SDK 26+.
    @MainActor var availability: SkillAvailability { get }

    /// Executes the native action with the parsed string argument.
    func execute(input: String) async throws -> String

    /// Whether running `input` would change state **outside** the app —
    /// creating a reminder, writing a calendar event, switching a light.
    ///
    /// Per-invocation rather than per-skill because several skills do both:
    /// `HomeKitSearch` with `"status"` only enumerates accessories, while the
    /// same skill with a set-power payload physically changes the home.
    ///
    /// Used by `SkillManager` to refuse a state-changing call in a turn that
    /// has already ingested untrusted content — see `producesUntrustedContent`.
    func isStateChanging(input: String) -> Bool

    /// Whether this skill's output can contain text controlled by someone
    /// other than the user — a fetched web page, a search-result snippet.
    ///
    /// Such output is fed straight back to the model as an observation, so it
    /// is an injection vector: the page can address the model directly and ask
    /// it to invoke another tool. Marking the source lets `SkillManager` track
    /// the taint rather than trying to detect the injection itself, which is
    /// not reliably possible.
    var producesUntrustedContent: Bool { get }
}

extension Skill {
    /// Default implementation — most skills don't need special OS
    /// permissions (Calculator, DeviceInfo, WebSearch). Skills that
    /// do (Calendar, HomeKit, Reminders) override this.
    @MainActor var availability: SkillAvailability { .enabled }

    /// Default: read-only. Skills that write to the world override this.
    ///
    /// Defaulting to `false` is the right way round despite being the less
    /// cautious default: the property is only consulted to *block* an action,
    /// and a skill that cannot change anything must not be blocked. Every
    /// skill that can write is overridden explicitly below, and the set is
    /// small and closed (Reminders, Calendar, HomeKit).
    func isStateChanging(input: String) -> Bool { false }

    /// Default: this skill's output originates from the device or the user.
    var producesUntrustedContent: Bool { false }
}
