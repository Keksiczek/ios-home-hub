import Foundation

/// Structured outcome of a tool invocation.
///
/// The old `SkillManager.execute(_:)` flattened everything into a single
/// `String` so the LLM could splice it into its next prompt. That's fine
/// for the happy path, but loses information the UI and the agentic
/// loop actually want to know: "did the tool refuse for permission
/// reasons?", "did it time out?", "did the parser skip a malformed
/// call?". This enum carries that distinction through the loop without
/// forcing callers to keyword-scan English error messages.
enum ToolExecutionResult: Equatable {
    /// Tool ran and produced text for the LLM to quote.
    case success(String)
    /// Tool was called but refused or errored. Payload is the
    /// user-presentable explanation; the LLM sees it as an
    /// `<Observation>` so it can apologise or retry.
    case error(message: String, reason: FailureReason)

    /// Convenience: the string the LLM will see inside `<Observation>`.
    /// Success is returned verbatim; failures are prefixed so small
    /// models learn the difference without needing keyword scans.
    var observationText: String {
        switch self {
        case .success(let text):
            return text
        case .error(let message, let reason):
            return "[tool error: \(reason.rawValue)] \(message)"
        }
    }

    /// `true` for success. Used by `ConversationService` to decide
    /// whether to loop back for another tool turn — a repeated failure
    /// on the same call shape should break out rather than retry.
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    enum FailureReason: String, Equatable {
        /// JSON envelope was malformed beyond recovery.
        case malformedCall
        /// The named tool isn't registered.
        case unknownTool
        /// The tool is registered but disabled in Settings.
        case disabled
        /// The tool needs an OS permission the user hasn't granted.
        case permissionMissing
        /// The tool ran long past the per-call budget and was cancelled.
        case timeout
        /// The tool raised an error from its own body.
        case executionFailed
    }
}

/// Whether a skill can actually run right now.
///
/// Driven by a combination of compile-time framework availability
/// (e.g. EventKit, HomeKit) and runtime permission state. The chat
/// surfaces this so the user sees a "Grant permission" button instead
/// of a cryptic "CalendarSkill failed" observation.
enum SkillAvailability: Equatable {
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

    /// `true` when the skill can actually run. Used to filter the
    /// `SkillManager` allow-list so the model never gets an
    /// `<Observation>` reading "Permission not granted".
    var isReady: Bool {
        if case .enabled = self { return true }
        return false
    }
}
