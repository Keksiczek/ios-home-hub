import Foundation
import SwiftUI

/// Throwaway draft state for onboarding. Lives only for the duration
/// of the flow; gets flushed into persisted services on `commit`.
@MainActor
final class OnboardingDrafts: ObservableObject {
    @Published var user: UserProfile = .blank
    @Published var assistant: AssistantProfile = .defaultAssistant
    @Published var memoryEnabled: Bool = true
    @Published var selectedModelID: String?

    var interestsText: Binding<String> {
        Binding<String>(
            get: { self.user.interests.joined(separator: ", ") },
            set: { newValue in
                self.user.interests = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
