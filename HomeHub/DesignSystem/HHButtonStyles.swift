import SwiftUI

struct HHPrimaryButtonStyle: ButtonStyle {
    var isLoading: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: HHTheme.spaceS) {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
            }
            configuration.label
                .font(HHTheme.headline)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                .fill(HHTheme.accent)
        )
        .opacity(configuration.isPressed ? 0.85 : 1.0)
        .scaleEffect(configuration.isPressed ? 0.99 : 1.0)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct HHSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HHTheme.headline)
            .foregroundStyle(HHTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                    .fill(HHTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                    .stroke(HHTheme.stroke, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

struct HHQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HHTheme.subheadline)
            .foregroundStyle(HHTheme.textSecondary)
            .padding(.horizontal, HHTheme.spaceM)
            .padding(.vertical, HHTheme.spaceS)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}
