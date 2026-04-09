import SwiftUI

/// Used in onboarding and settings for illustrative feature lists.
struct HHFeatureRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: HHTheme.spaceL) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(HHTheme.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: HHTheme.cornerSmall, style: .continuous)
                        .fill(HHTheme.accentSoft)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HHTheme.headline)
                    .foregroundStyle(HHTheme.textPrimary)
                Text(text)
                    .font(HHTheme.footnote)
                    .foregroundStyle(HHTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
