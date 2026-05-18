import Foundation
import SwiftUI

/// Owns the persisted onboarding state machine. Views observe
/// `state` and call `advance(to:)` / `commit(...)` to move through
/// the flow.
@MainActor
final class OnboardingService: ObservableObject {
    @Published var state: OnboardingState = .initial

    /// Set during `load()` when the device already has installed models
    /// (typical iCloud / Quick Start restore). The Welcome screen can
    /// read this to surface a "We found N models — get started without
    /// downloading" CTA so returning users don't have to walk through
    /// the multi-GB download flow a second time.
    @Published private(set) var restoredModelIDs: [String] = []

    private let store: any Store
    private let settings: SettingsService
    private let personalization: PersonalizationService
    private let appState: AppState
    /// Optional probe used during `load()` to discover already-installed
    /// models. Injected as a closure to avoid a hard dependency on
    /// `LocalModelService` (which OnboardingService doesn't otherwise
    /// need). Returns the model IDs / repo IDs the user can immediately
    /// start using. Defaults to empty when not provided.
    private let installedModelProbe: (@Sendable () async -> [String])?

    init(
        store: any Store,
        settings: SettingsService,
        personalization: PersonalizationService,
        appState: AppState,
        installedModelProbe: (@Sendable () async -> [String])? = nil
    ) {
        self.store = store
        self.settings = settings
        self.personalization = personalization
        self.appState = appState
        self.installedModelProbe = installedModelProbe
    }

    func load() async {
        do {
            if let loaded = try await store.loadOnboardingState() {
                state = loaded
            }
        } catch {
            HHLog.settings.error("loadOnboardingState failed: \(error.localizedDescription, privacy: .public)")
        }

        // Probe for restored / pre-existing model files. Onboarding is
        // only relevant while `isCompleted == false`, so we skip the
        // probe entirely once the user is past first-run — saving the
        // disk walk on every launch.
        if !state.isCompleted, let probe = installedModelProbe {
            let found = await probe()
            if !found.isEmpty {
                restoredModelIDs = found
                HHLog.settings.info("OnboardingService: detected \(found.count, privacy: .public) pre-existing model(s); offering skip path")
            }
        }
    }

    /// Convenience: short-circuits the multi-step download flow when
    /// the user accepts the "use the restored model" CTA. Selects the
    /// first restored model, marks onboarding completed with default
    /// memory settings, and lands the app in `.ready`. The user can
    /// always adjust personalization / memory later from Settings.
    func acceptRestoredModel(_ modelID: String) async {
        let user = personalization.userProfile
        let assistant = personalization.assistantProfile
        await commit(
            user: user,
            assistant: assistant,
            memoryEnabled: true,
            selectedModelID: modelID
        )
    }

    func advance(to step: OnboardingState.Step) async {
        state.currentStep = step
        do {
            try await store.save(onboardingState: state)
        } catch {
            HHLog.settings.error("save onboardingState failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func back(to step: OnboardingState.Step) async {
        await advance(to: step)
    }

    /// Finalize onboarding: write the user profile, assistant profile,
    /// memory preference, and selected model, then transition the app
    /// to `.ready`.
    func commit(
        user: UserProfile,
        assistant: AssistantProfile,
        memoryEnabled: Bool,
        selectedModelID: String? = nil
    ) async {
        await personalization.update(user: user)
        await personalization.update(assistant: assistant)

        var nextSettings = settings.current
        nextSettings.memoryEnabled = memoryEnabled
        nextSettings.autoExtractMemory = memoryEnabled
        nextSettings.selectedModelID = selectedModelID
        await settings.update(nextSettings)

        state.isCompleted = true
        state.currentStep = .finish
        do {
            try await store.save(onboardingState: state)
        } catch {
            HHLog.settings.error("save onboardingState (commit) failed: \(error.localizedDescription, privacy: .public)")
        }

        appState.phase = .ready
    }

    /// Restart onboarding. Wipes personalization (but not memory) and
    /// flips the app back to the onboarding phase.
    ///
    /// Also clears the Hugging Face token + its verification metadata
    /// so the new user of this install doesn't inherit the previous
    /// account's HF identity. Chats, memory, and installed models are
    /// deliberately preserved (the Settings footer copy promises this).
    /// The pressure history is short-lived runtime state — it lives on
    /// `AppContainer.pressureHistory` and is reset when the app process
    /// next launches anyway, so we don't need to touch it here.
    func reset() async {
        await personalization.reset()
        HFTokenStore.clearAll()
        state = .initial
        do {
            try await store.save(onboardingState: state)
        } catch {
            HHLog.settings.error("save onboardingState (reset) failed: \(error.localizedDescription, privacy: .public)")
        }
        appState.phase = .onboarding
    }
}
