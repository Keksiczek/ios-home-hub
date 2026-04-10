import SwiftUI

struct OnboardingFinishView: View {
    @EnvironmentObject private var service: OnboardingService
    @EnvironmentObject private var memory: MemoryService
    @ObservedObject var drafts: OnboardingDrafts

    var body: some View {
        HHScreen(
            eyebrow: "All set",
            title: "You're ready.",
            subtitle: "Here's what the assistant will know about you. You can edit any of this later."
        ) {
            VStack(alignment: .leading, spacing: HHTheme.spaceL) {
                HHCard {
                    VStack(alignment: .leading, spacing: HHTheme.spaceS) {
                        summaryRow("Assistant", value: drafts.assistant.name)
                        summaryRow("Tone", value: drafts.assistant.tone.label)
                        summaryRow("Response style", value: drafts.user.preferredResponseStyle.label)
                        summaryRow("Memory", value: drafts.memoryEnabled ? "On" : "Off")
                        if !drafts.user.displayName.isEmpty {
                            summaryRow("Name", value: drafts.user.displayName)
                        }
                        if let occ = drafts.user.occupation, !occ.isEmpty {
                            summaryRow("Work", value: occ)
                        }
                        if !drafts.user.interests.isEmpty {
                            summaryRow("Interests", value: drafts.user.interests.joined(separator: ", "))
                        }
                    }
                }
            }
        } footer: {
            VStack(spacing: HHTheme.spaceS) {
                Button("Start chatting") {
                    Task { await finish() }
                }
                .buttonStyle(HHPrimaryButtonStyle())

                Button("Back") {
                    Task { await service.back(to: .profile) }
                }
                .buttonStyle(HHQuietButtonStyle())
            }
        }
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(HHTheme.footnote)
                .foregroundStyle(HHTheme.textSecondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(HHTheme.body)
                .foregroundStyle(HHTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func finish() async {
        // Seed memory with the profile answers so the very first chat
        // can reference them. Each becomes an `onboarding`-sourced fact.
        if drafts.memoryEnabled {
            if let occ = drafts.user.occupation, !occ.isEmpty {
                await memory.add(MemoryFact(
                    id: UUID(),
                    content: "Works as \(occ)",
                    category: .work,
                    source: .onboarding,
                    confidence: 1.0,
                    createdAt: .now, lastUsedAt: nil,
                    pinned: true, disabled: false
                ))
            }
            if let ctx = drafts.user.workingContext, !ctx.isEmpty {
                await memory.add(MemoryFact(
                    id: UUID(),
                    content: "Currently focused on: \(ctx)",
                    category: .projects,
                    source: .onboarding,
                    confidence: 1.0,
                    createdAt: .now, lastUsedAt: nil,
                    pinned: true, disabled: false
                ))
            }
            for interest in drafts.user.interests {
                await memory.add(MemoryFact(
                    id: UUID(),
                    content: "Interested in \(interest)",
                    category: .preferences,
                    source: .onboarding,
                    confidence: 0.9,
                    createdAt: .now, lastUsedAt: nil,
                    pinned: false, disabled: false
                ))
            }
        }

        await service.commit(
            user: drafts.user,
            assistant: drafts.assistant,
            memoryEnabled: drafts.memoryEnabled,
            selectedModelID: drafts.selectedModelID
        )
    }
}
