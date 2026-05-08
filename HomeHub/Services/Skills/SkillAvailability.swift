import Foundation

/// Describes the runtime availability of a Skill on the current device.
enum SkillAvailability: Sendable, Equatable {
    /// The skill is fully enabled and ready to be executed.
    case enabled
    
    /// The skill requires a specific OS permission that hasn't been granted yet.
    /// - Parameter prompt: A human-readable description of what permission is needed (e.g., "Calendar access").
    case permission(String)
    
    /// The skill is completely unavailable on this device or OS version.
    /// - Parameter reason: A human-readable explanation (e.g., "Requires iOS 18.0").
    case unavailable(String)
}
