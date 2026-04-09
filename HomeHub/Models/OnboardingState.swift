import Foundation

struct OnboardingState: Codable, Equatable {
    var isCompleted: Bool
    var currentStep: Step

    enum Step: String, Codable, CaseIterable {
        case welcome
        case modelSelection
        case assistantStyle
        case memoryConsent
        case profile
        case finish
    }

    static let initial = OnboardingState(isCompleted: false, currentStep: .welcome)

    var progress: Double {
        guard let idx = Step.allCases.firstIndex(of: currentStep) else { return 0 }
        return Double(idx + 1) / Double(Step.allCases.count)
    }
}
