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
}

enum MainTab: Hashable {
    case chat
    case memory
    case models
    case settings
}
