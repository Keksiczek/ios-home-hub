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
    @Published var selectedTab: MainTab = .chat

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
            // Document detail lives under Settings → Developer → KB
            // for now; opening the Settings tab and surfacing the
            // pending link there keeps routing honest until KB
            // becomes a top-level tab.
            selectedTab = .settings
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
    case chat
    case memory
    case models
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .chat:     return "Chat"
        case .memory:   return "Memory"
        case .models:   return "Models"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chat:     return "bubble.left.and.bubble.right"
        case .memory:   return "sparkles"
        case .models:   return "cube.box"
        case .settings: return "gearshape"
        }
    }
}
