import SwiftUI

struct OnboardingMemoryConsentView: View {
    @EnvironmentObject private var service: OnboardingService
    @ObservedObject var drafts: OnboardingDrafts

    var body: some View {
        HHScreen(
            eyebrow: "Step 3",
            title: "Should it remember things?",
            subtitle: "Memory is off by default in most AI apps. Here it's a first-class feature — but only if you want it."
        ) {
            VStack(alignment: .leading, spacing: HHTheme.spaceL) {
                HHCard {
                    VStack(alignment: .leading, spacing: HHTheme.spaceM) {
                        Toggle(isOn: $drafts.memoryEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable memory")
                                    .font(HHTheme.headline)
                                Text("The assistant can save important facts and recall them across chats.")
                                    .font(HHTheme.footnote)
                                    .foregroundStyle(HHTheme.textSecondary)
                            }
                        }
                        .tint(HHTheme.accent)
                    }
                }

                VStack(alignment: .leading, spacing: HHTheme.spaceM) {
                    HHFeatureRow(
                        icon: "checkmark.shield",
                        title: "You're always in control",
                        text: "See, edit, pin, disable, or delete any fact at any time in the Memory tab."
                    )
                    HHFeatureRow(
                        icon: "eye.slash",
                        title: "Nothing is implicit",
                        text: "Proposed facts appear as cards you can accept or reject — nothing is saved silently."
                    )
                    HHFeatureRow(
                        icon: "iphone",
                        title: "Local only",
                        text: "Memory lives in your device's protected storage. It never syncs or uploads."
                    )
                }
            }
        } footer: {
            VStack(spacing: HHTheme.spaceS) {
                Button("Continue") {
                    Task { await service.advance(to: .profile) }
                }
                .buttonStyle(HHPrimaryButtonStyle())

                Button("Back") {
                    Task { await service.back(to: .assistantStyle) }
                }
                .buttonStyle(HHQuietButtonStyle())
            }
        }
    }
}
