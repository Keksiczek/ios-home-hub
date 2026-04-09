import SwiftUI

struct OnboardingProfileView: View {
    @EnvironmentObject private var service: OnboardingService
    @ObservedObject var drafts: OnboardingDrafts

    var body: some View {
        HHScreen(
            eyebrow: "Step 4",
            title: "A little about you.",
            subtitle: "Optional — and editable anytime. This shapes how the assistant talks and what it prioritizes."
        ) {
            VStack(alignment: .leading, spacing: HHTheme.spaceL) {
                HHCard {
                    VStack(alignment: .leading, spacing: HHTheme.spaceM) {
                        ProfileField(label: "What should it call you?",
                                     placeholder: "Your name",
                                     text: $drafts.user.displayName)
                        Divider()
                        ProfileField(label: "What do you do?",
                                     placeholder: "e.g. Product designer",
                                     text: Binding(
                                        get: { drafts.user.occupation ?? "" },
                                        set: { drafts.user.occupation = $0.isEmpty ? nil : $0 }
                                     ))
                        Divider()
                        ProfileField(label: "Interests (comma-separated)",
                                     placeholder: "typography, running, espresso",
                                     text: drafts.interestsText)
                        Divider()
                        ProfileField(label: "What are you focused on right now?",
                                     placeholder: "e.g. Launching a meditation app",
                                     text: Binding(
                                        get: { drafts.user.workingContext ?? "" },
                                        set: { drafts.user.workingContext = $0.isEmpty ? nil : $0 }
                                     ))
                    }
                }

                VStack(alignment: .leading, spacing: HHTheme.spaceS) {
                    Text("Response style")
                        .font(HHTheme.subheadline)
                        .foregroundStyle(HHTheme.textSecondary)

                    VStack(spacing: HHTheme.spaceS) {
                        ForEach(ResponseStyle.allCases) { style in
                            StyleRow(
                                style: style,
                                isSelected: drafts.user.preferredResponseStyle == style,
                                onSelect: { drafts.user.preferredResponseStyle = style }
                            )
                        }
                    }
                }
            }
        } footer: {
            VStack(spacing: HHTheme.spaceS) {
                Button("Continue") {
                    Task { await service.advance(to: .finish) }
                }
                .buttonStyle(HHPrimaryButtonStyle())

                Button("Skip") {
                    Task { await service.advance(to: .finish) }
                }
                .buttonStyle(HHQuietButtonStyle())
            }
        }
    }
}

private struct ProfileField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceS) {
            Text(label)
                .font(HHTheme.subheadline)
                .foregroundStyle(HHTheme.textSecondary)
            TextField(placeholder, text: $text)
                .font(HHTheme.body)
                .textInputAutocapitalization(.sentences)
        }
    }
}

private struct StyleRow: View {
    let style: ResponseStyle
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: HHTheme.spaceM) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? HHTheme.accent : HHTheme.textSecondary.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.label)
                        .font(HHTheme.headline)
                        .foregroundStyle(HHTheme.textPrimary)
                    Text(style.blurb)
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
