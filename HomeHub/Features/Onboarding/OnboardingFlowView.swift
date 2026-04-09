import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var service: OnboardingService
    @StateObject private var drafts = OnboardingDrafts()

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: service.state.progress)
                .tint(HHTheme.accent)
                .padding(.horizontal, HHTheme.spaceXL)
                .padding(.top, HHTheme.spaceL)

            Group {
                switch service.state.currentStep {
                case .welcome:
                    OnboardingWelcomeView()
                case .modelSelection:
                    OnboardingModelPickerView(drafts: drafts)
                case .assistantStyle:
                    OnboardingAssistantStyleView(drafts: drafts)
                case .memoryConsent:
                    OnboardingMemoryConsentView(drafts: drafts)
                case .profile:
                    OnboardingProfileView(drafts: drafts)
                case .finish:
                    OnboardingFinishView(drafts: drafts)
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: service.state.currentStep)
        }
        .background(HHTheme.canvas.ignoresSafeArea())
    }
}

#Preview("Welcome") {
    let container = AppContainer.preview()
    container.onboardingService.state = .initial
    return OnboardingFlowView()
        .environmentObject(container.onboardingService)
        .environmentObject(container.modelCatalogService)
        .environmentObject(container.modelDownloadService)
        .environmentObject(container.memoryService)
}
