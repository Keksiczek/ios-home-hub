import SwiftUI

struct OnboardingAssistantStyleView: View {
    @EnvironmentObject private var service: OnboardingService
    @ObservedObject var drafts: OnboardingDrafts

    var body: some View {
        HHScreen(
            eyebrow: "Step 2",
            title: "Give your assistant a name and a tone.",
            subtitle: "This shapes how it talks to you. You can change it any time in Settings."
        ) {
            VStack(alignment: .leading, spacing: HHTheme.spaceL) {
                HHCard {
                    VStack(alignment: .leading, spacing: HHTheme.spaceS) {
                        Text("Name")
                            .font(HHTheme.subheadline)
                            .foregroundStyle(HHTheme.textSecondary)
                        TextField("Home", text: $drafts.assistant.name)
                            .font(HHTheme.headline)
                            .textInputAutocapitalization(.words)
                    }
                }

                VStack(alignment: .leading, spacing: HHTheme.spaceS) {
                    Text("Tone")
                        .font(HHTheme.subheadline)
                        .foregroundStyle(HHTheme.textSecondary)

                    VStack(spacing: HHTheme.spaceS) {
                        ForEach(AssistantTone.allCases) { tone in
                            ToneRow(
                                tone: tone,
                                isSelected: drafts.assistant.tone == tone,
                                onSelect: { drafts.assistant.tone = tone }
                            )
                        }
                    }
                }
            }
        } footer: {
            VStack(spacing: HHTheme.spaceS) {
                Button("Continue") {
                    Task { await service.advance(to: .memoryConsent) }
                }
                .buttonStyle(HHPrimaryButtonStyle())

                Button("Back") {
                    Task { await service.back(to: .modelSelection) }
                }
                .buttonStyle(HHQuietButtonStyle())
            }
        }
    }
}

private struct ToneRow: View {
    let tone: AssistantTone
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: HHTheme.spaceM) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? HHTheme.accent : HHTheme.textSecondary.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tone.label)
                        .font(HHTheme.headline)
                        .foregroundStyle(HHTheme.textPrimary)
                    Text(tone.blurb)
                        .font(HHTheme.footnote)
                        .foregroundStyle(HHTheme.textSecondary)
                }
                Spacer()
            }
            .padding(HHTheme.spaceM)
            .background(
                RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                    .fill(HHTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                    .stroke(isSelected ? HHTheme.accent : HHTheme.stroke, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
