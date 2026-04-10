import UIKit

/// Thin wrapper around UIFeedbackGenerator that respects the user's
/// haptics setting. All methods are no-ops when `enabled` is false.
///
/// Usage from any view with access to SettingsService:
/// ```swift
/// HHHaptics.impact(.medium, enabled: settings.current.haptics)
/// ```
enum HHHaptics {

    // MARK: - Impact

    enum ImpactWeight {
        case light, medium, heavy, soft, rigid

        fileprivate var style: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light:  return .light
            case .medium: return .medium
            case .heavy:  return .heavy
            case .soft:   return .soft
            case .rigid:  return .rigid
            }
        }
    }

    @MainActor
    static func impact(_ weight: ImpactWeight = .medium, enabled: Bool) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: weight.style).impactOccurred()
    }

    // MARK: - Notification

    enum NotificationType {
        case success, warning, error

        fileprivate var feedbackType: UINotificationFeedbackGenerator.FeedbackType {
            switch self {
            case .success: return .success
            case .warning: return .warning
            case .error:   return .error
            }
        }
    }

    @MainActor
    static func notification(_ type: NotificationType, enabled: Bool) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type.feedbackType)
    }

    // MARK: - Selection

    @MainActor
    static func selection(enabled: Bool) {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
