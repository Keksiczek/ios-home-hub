import SwiftUI

struct HHCard<Content: View>: View {
    var padding: CGFloat = HHTheme.spaceL
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                    .fill(HHTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                    .stroke(HHTheme.stroke, lineWidth: 1)
            )
    }
}

struct HHSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceXS) {
            Text(title)
                .font(HHTheme.headline)
                .foregroundStyle(HHTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(HHTheme.footnote)
                    .foregroundStyle(HHTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HHTagChip: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(HHTheme.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(HHTheme.accent)
        .background(
            Capsule().fill(HHTheme.accentSoft)
        )
    }
}
