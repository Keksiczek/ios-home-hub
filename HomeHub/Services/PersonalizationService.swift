import Foundation
import SwiftUI

/// Holds the current `UserProfile` and `AssistantProfile`. These are
/// the two inputs (alongside memory) that make the assistant feel
/// consistent across sessions.
@MainActor
final class PersonalizationService: ObservableObject {
    @Published private(set) var userProfile: UserProfile
    @Published private(set) var assistantProfile: AssistantProfile

    private let store: any Store

    init(store: any Store, defaultUser: UserProfile, defaultAssistant: AssistantProfile) {
        self.store = store
        self.userProfile = defaultUser
        self.assistantProfile = defaultAssistant
    }

    func load() async {
        do {
            if let savedUser = try await store.loadUserProfile() {
                userProfile = savedUser
            }
        } catch {
            HHLog.settings.error("loadUserProfile failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            if let savedAssistant = try await store.loadAssistantProfile() {
                assistantProfile = savedAssistant
            }
        } catch {
            HHLog.settings.error("loadAssistantProfile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(user: UserProfile) async {
        var next = user
        next.updatedAt = .now
        userProfile = next
        do {
            try await store.save(userProfile: next)
        } catch {
            HHLog.settings.error("save userProfile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(assistant: AssistantProfile) async {
        assistantProfile = assistant
        do {
            try await store.save(assistant: assistant)
        } catch {
            HHLog.settings.error("save assistant failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reset personalization without touching memory facts.
    /// Memory reset is an independent action in the Memory view.
    func reset() async {
        let blank = UserProfile.blank
        let assistant = AssistantProfile.defaultAssistant
        await update(user: blank)
        await update(assistant: assistant)
    }
}
