import SwiftUI

/// Design tokens for HomeHub. Deliberately restrained: one accent,
/// flat neutrals, no gradients, no glow effects. The goal is a calm
/// "quality product" feel inspired by Enclave — not a sci-fi AI vibe.
enum HHTheme {
    // Colors
    static let accent       = Color(red: 0.29, green: 0.50, blue: 0.94)
    static let accentSoft   = Color(red: 0.29, green: 0.50, blue: 0.94).opacity(0.10)
    static let canvas       = Color(.systemBackground)
    static let surface      = Color(.secondarySystemBackground)
    static let surfaceRaised = Color(.tertiarySystemBackground)
    static let textPrimary  = Color.primary
    static let textSecondary = Color.secondary
    static let stroke       = Color.primary.opacity(0.07)
    static let success      = Color.green
    static let warning      = Color.orange
    static let danger       = Color.red

    // Radius
    static let cornerSmall: CGFloat = 10
    static let cornerMedium: CGFloat = 16
    static let cornerLarge: CGFloat = 22

    // Spacing
    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat  = 8
    static let spaceM: CGFloat  = 12
    static let spaceL: CGFloat  = 16
    static let spaceXL: CGFloat = 24
    static let spaceXXL: CGFloat = 32

    // Typography
    static let largeTitle = Font.system(size: 34, weight: .semibold, design: .default)
    static let title      = Font.system(size: 28, weight: .semibold, design: .default)
    static let title2     = Font.system(size: 22, weight: .semibold, design: .default)
    static let headline   = Font.system(size: 17, weight: .semibold, design: .default)
    static let body       = Font.system(size: 17, weight: .regular, design: .default)
    static let callout    = Font.system(size: 15, weight: .regular, design: .default)
    static let subheadline = Font.system(size: 14, weight: .medium, design: .default)
    static let footnote   = Font.system(size: 13, weight: .regular, design: .default)
    static let caption    = Font.system(size: 12, weight: .regular, design: .default)
    static let eyebrow    = Font.system(size: 12, weight: .semibold, design: .default).uppercaseSmallCaps()
}
