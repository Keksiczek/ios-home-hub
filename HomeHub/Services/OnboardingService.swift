import Foundation
import SwiftUI

/// Owns the persisted onboarding state machine. Views observe
/// `state` and call `advance(to:)` / `commit(...)` to move through
/// the flow.
@MainActor
final class OnboardingService: ObservableObject {
    @Published var state: OnboardingState = .initial

    private let store: any Store
    private let settings: SettingsService
    private let personalization: PersonalizationService
    private let appState: AppState

    init(
        store: any Store,
        settings: SettingsService,
        personalization: PersonalizationService,
        appState: AppState
    ) {
        self.store = store
        self.settings = settings
        self.personalization = personalization
        self.appState = appState
    }

    func load() async {
        if let loaded = try? await store.loadOnboardingState() {
            state = loaded
        }
    }

    func advance(to step: OnboardingState.Step) async {
        state.currentStep = step
        try? await store.save(onboardingState: state)
    }

    func back(to step: OnboardingState.Step) async {
        await advance(to: step)
    }

    /// Finalize onboarding: write the user profile, assistant profile,
    /// and memory preference, then transition the app to `.ready`.
    func commit(
        user: UserProfile,
        assistant: AssistantProfile,
        memoryEnabled: Bool
    ) async {
        await personalization.update(user: user)
        await personalization.update(assistant: assistant)

        var nextSettings = settings.current
        nextSettings.memoryEnabled = memoryEnabled
        nextSettings.autoExtractMemory = memoryEnabled
        await settings.update(nextSettings)

        state.isCompleted = true
        state.currentStep = .finish
        try? await store.save(onboardingState: state)

        appState.phase = .ready
    }

    /// Restart onboarding. Wipes personalization (but not memory) and
    /// flips the app back to the onboarding phase.
    func reset() async {
        await personalization.reset()
        state = .initial
        try? await store.save(onboardingState: state)
        appState.phase = .onboarding
    }
}
