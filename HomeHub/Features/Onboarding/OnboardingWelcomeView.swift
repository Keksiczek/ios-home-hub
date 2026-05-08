import SwiftUI

struct OnboardingWelcomeView: View {
    @EnvironmentObject private var service: OnboardingService

    var body: some View {
        HHScreen(
            eyebrow: "HomeHub",
            title: "Your private AI,\nlocally on your device.",
            subtitle: "No accounts. No cloud. Everything stays on your iPhone or iPad — always."
        ) {
            VStack(alignment: .leading, spacing: HHTheme.spaceL) {
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(HHTheme.accent.opacity(0.1))
                            .frame(width: 80, height: 80)
                        Image(systemName: "sparkles")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(HHTheme.accent)
                    }
                    Spacer()
                }
                .padding(.bottom, HHTheme.spaceM)
                HHFeatureRow(
                    icon: "lock.shield.fill",
                    title: "Fully on-device",
                    text: "Inference, history, and memory never leave your device."
                )
                HHFeatureRow(
                    icon: "brain.head.profile",
                    title: "Personal memory",
                    text: "Opt-in facts it can recall across chats, always in your control."
                )
                HHFeatureRow(
                    icon: "bolt.fill",
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
