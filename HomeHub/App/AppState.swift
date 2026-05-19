import Foundation

/// Top-level app phase + navigation selection.
///
/// Owned by `AppContainer` and injected into the view hierarchy as an
/// `EnvironmentObject`. Every service that needs to hand control back
/// to the top-level navigation (e.g. onboarding completion) mutates
/// `phase` on the main actor.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case launching
        case onboarding
        case ready
    }

    @Published var phase: Phase = .launching
    /// Currently-selected top-level destination. Persists the user's
    /// last choice in `UserDefaults` under `app.selectedTab` so a
    /// relaunch lands where they left off rather than always defaulting
    /// to the dashboard — power users who live in Chat shouldn't have
    /// to re-tap a tab every cold start.
    @Published var selectedTab: MainTab = AppState.loadPersistedTab() {
        didSet {
            UserDefaults.standard.set(selectedTab.persistedKey, forKey: AppState.selectedTabKey)
        }
    }

    private static let selectedTabKey = "app.selectedTab"

    private static func loadPersistedTab() -> MainTab {
        guard let raw = UserDefaults.standard.string(forKey: selectedTabKey),
              let tab = MainTab(persistedKey: raw)
        else { return .dashboard }
        return tab
    }

    /// Pending deep-link request from a Spotlight tap, custom URL,
    /// or App Intent. Set by `HomeHubApp.onContinueUserActivity`
    /// / `.onOpenURL` and consumed by views that observe it (chat
    /// list opens the conversation, memory tab scrolls to fact,
    /// etc.). Each consumer is responsible for clearing the value
    /// after handling — leaving it set would re-fire on every
    /// state change.
    @Published var pendingDeepLink: DeepLink?

    /// Funnels every external entry point into a single mutation
    /// so view code only has to react to `pendingDeepLink`. Sets
    /// `selectedTab` synchronously so the view stack switches
    /// before the deep-link consumer reads it (avoids a frame of
    /// "wrong tab" flicker).
    func handle(deepLink: DeepLink) {
        switch deepLink {
        case .document:
            selectedTab = .knowledgeBase
        case .conversation:
            selectedTab = .chat
        case .memoryFact:
            selectedTab = .memory
        case .query:
            selectedTab = .chat
        }
        pendingDeepLink = deepLink
    }

    /// Marks a deep link as consumed. Views call this after they've
    /// scrolled / navigated / opened the target.
    func clearPendingDeepLink() {
        pendingDeepLink = nil
    }
}

enum MainTab: Hashable, CaseIterable, Identifiable {
    case dashboard
    case chat
    case knowledgeBase
    case memory
    case models
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard:     return "Home"
        case .chat:          return "Chat"
        case .knowledgeBase: return "Documents"
        case .memory:        return "Memory"
        case .models:        return "Models"
        case .settings:      return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard:     return "house.fill"
        case .chat:          return "bubble.left.and.bubble.right"
        case .knowledgeBase: return "doc.text.fill"
        case .memory:        return "sparkles"
        case .models:        return "cube.box"
        case .settings:      return "gearshape"
        }
    }

    /// Stable identifier used for `UserDefaults` persistence. Decoupled
    /// from `String(describing:)` so renaming the case in source doesn't
    /// silently invalidate persisted user state.
    var persistedKey: String {
        switch self {
        case .dashboard:     return "dashboard"
        case .chat:          return "chat"
        case .knowledgeBase: return "knowledgeBase"
        case .memory:        return "memory"
        case .models:        return "models"
        case .settings:      return "settings"
        }
    }

    init?(persistedKey: String) {
        switch persistedKey {
        case "dashboard":     self = .dashboard
        case "chat":          self = .chat
        case "knowledgeBase": self = .knowledgeBase
        case "memory":        self = .memory
        case "models":        self = .models
        case "settings":      self = .settings
        default:              return nil
        }
    }
}
