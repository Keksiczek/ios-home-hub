import SwiftUI

struct OnboardingWelcomeView: View {
    @EnvironmentObject private var service: OnboardingService

    var body: some View {
        HHScreen(
            eyebrow: "HomeHub",
            title: "A private assistant\nthat lives on your device.",
            subtitle: "No accounts. No cloud. Your conversations, memory, and models stay on this iPhone or iPad — always."
        ) {
            VStack(alignment: .leading, spacing: HHTheme.spaceL) {
                HHFeatureRow(
                    icon: "lock.shield",
                    title: "Fully on-device",
                    text: "Inference, history, and memory never leave your device."
                )
                HHFeatureRow(
                    icon: "brain",
                    title: "Personal memory",
                    text: "Opt-in facts it can recall across chats, always in your control."
                )
                HHFeatureRow(
                    icon: "bolt",
                    title: "Built for Apple silicon",
                    text: "Tuned for iPhone 16 Pro and M-series iPad."
                )
            }
        } footer: {
            Button("Continue") {
                Task { await service.advance(to: .modelSelection) }
            }
            .buttonStyle(HHPrimaryButtonStyle())
        }
    }
}
