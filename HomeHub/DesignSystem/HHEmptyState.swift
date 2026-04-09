import SwiftUI

struct HHEmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: HHTheme.spaceL) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(HHTheme.textSecondary)

            VStack(spacing: HHTheme.spaceS) {
                Text(title)
                    .font(HHTheme.title2)
                    .foregroundStyle(HHTheme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(HHTheme.callout)
                    .foregroundStyle(HHTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, HHTheme.spaceXL)

            actions()
                .padding(.top, HHTheme.spaceS)
                .padding(.horizontal, HHTheme.spaceXL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension HHEmptyState where Actions == EmptyView {
    init(icon: String, title: String, subtitle: String) {
        self.init(icon: icon, title: title, subtitle: subtitle) { EmptyView() }
    }
}
