import Foundation

/// Whether a skill can actually run right now.
///
/// Driven by a combination of compile-time framework availability
/// (e.g. EventKit, HomeKit) and runtime permission state. The chat
/// surfaces this so the user sees a "Grant permission" button instead
/// of a cryptic "CalendarSkill failed" observation.
enum SkillAvailability: Sendable, Equatable {
    /// Ready to run — either no permission needed, or the permission
    /// has already been granted.
    case enabled
    /// Framework or hardware the skill depends on isn't present on
    /// this device. Explanation is user-readable.
    case unavailable(reason: String)
    /// A permission is required before the skill can be used. The
    /// caller should surface a "Grant permission" action that maps to
    /// the named prompt.
    case permission(prompt: String)

    var label: String {
        switch self {
        case .enabled:                 return "Enabled"
        case .unavailable(let reason): return "Unavailable — \(reason)"
        case .permission(let prompt):  return "Needs permission — \(prompt)"
        }
    }

    /// `true` when the skill can actually run.
    var isReady: Bool {
        if case .enabled = self { return true }
        return false
    }
}
