import SwiftUI

/// Shared layout for onboarding steps. Keeps vertical rhythm
/// consistent across the flow without introducing a heavier
/// navigation abstraction.
struct HHScreen<Content: View, Footer: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: HHTheme.spaceL) {
                    if let eyebrow {
                        Text(eyebrow)
                            .font(HHTheme.eyebrow)
                            .foregroundStyle(HHTheme.accent)
                            .tracking(1.2)
                    }
                    Text(title)
                        .font(HHTheme.largeTitle)
                        .foregroundStyle(HHTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(HHTheme.body)
                            .foregroundStyle(HHTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content()
                        .padding(.top, HHTheme.spaceM)
                }
                .padding(.horizontal, HHTheme.spaceXL)
                .padding(.top, HHTheme.spaceXXL)
                .padding(.bottom, HHTheme.spaceXXL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer()
                .padding(.horizontal, HHTheme.spaceXL)
                .padding(.bottom, HHTheme.spaceXL)
        }
        .background(HHTheme.canvas.ignoresSafeArea())
    }
}
