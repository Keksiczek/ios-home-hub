import SwiftUI

/// Design tokens for HomeHub.
///
/// v2: Premium refresh — curated gradients, tinted materials, refined
/// typography with SF Rounded, and animation presets for micro-
/// interactions. Maintains the calm "quality product" feel while
/// adding depth and polish expected from a personal AI hub.
enum HHTheme {

    // MARK: - Core Colors

    /// Primary accent — a deep, luminous indigo-blue.
    static let accent       = Color(hue: 0.62, saturation: 0.65, brightness: 0.94)
    static let accentSoft   = accent.opacity(0.10)
    static let accentVibrant = Color(hue: 0.62, saturation: 0.50, brightness: 1.0)

    static let canvas       = Color(.systemBackground)
    static let surface      = Color(.secondarySystemBackground)
    static let surfaceRaised = Color(.tertiarySystemBackground)
    static let textPrimary  = Color.primary
    static let textSecondary = Color.secondary
    static let stroke       = Color.primary.opacity(0.07)

    // MARK: - Semantic Colors

    static let success      = Color(hue: 0.38, saturation: 0.65, brightness: 0.82)
    static let warning      = Color(hue: 0.10, saturation: 0.75, brightness: 0.95)
    static let danger       = Color(hue: 0.0,  saturation: 0.65, brightness: 0.88)
    static let info         = Color(hue: 0.55, saturation: 0.45, brightness: 0.90)

    // MARK: - Gradients

    /// Primary gradient for hero elements, buttons, onboarding.
    static let accentGradient = LinearGradient(
        colors: [
            Color(hue: 0.68, saturation: 0.60, brightness: 0.90),
            Color(hue: 0.58, saturation: 0.55, brightness: 0.95)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Subtle ambient glow for elevated cards.
    static let glowGradient = RadialGradient(
        colors: [accent.opacity(0.15), .clear],
        center: .topLeading,
        startRadius: 0,
        endRadius: 200
    )

    /// Mesh-like backdrop for onboarding / empty states.
    static let meshBackground = LinearGradient(
        colors: [
            Color(hue: 0.68, saturation: 0.12, brightness: 0.14),
            Color(hue: 0.58, saturation: 0.08, brightness: 0.10),
            Color(hue: 0.50, saturation: 0.05, brightness: 0.08)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Radius

    static let cornerSmall: CGFloat = 10
    static let cornerMedium: CGFloat = 16
    static let cornerLarge: CGFloat = 22
    static let cornerXL: CGFloat = 28

    // MARK: - Spacing

    static let spaceXS: CGFloat = 4
    static let spaceS: CGFloat  = 8
    static let spaceM: CGFloat  = 12
    static let spaceL: CGFloat  = 16
    static let spaceXL: CGFloat = 24
    static let spaceXXL: CGFloat = 32

    // MARK: - Typography (SF Rounded for warmth)

    static let largeTitle  = Font.system(size: 34, weight: .bold, design: .rounded)
    static let title       = Font.system(size: 28, weight: .bold, design: .rounded)
    static let title2      = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let title3      = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let headline    = Font.system(size: 17, weight: .semibold, design: .default)
    static let body        = Font.system(size: 17, weight: .regular, design: .default)
    static let callout     = Font.system(size: 15, weight: .regular, design: .default)
    static let subheadline = Font.system(size: 14, weight: .medium, design: .default)
    static let footnote    = Font.system(size: 13, weight: .regular, design: .default)
    static let caption     = Font.system(size: 12, weight: .regular, design: .default)
    static let eyebrow     = Font.system(size: 12, weight: .bold, design: .rounded).uppercaseSmallCaps()
    /// Monospaced for code blocks, token counters, stats.
    static let mono        = Font.system(size: 14, weight: .medium, design: .monospaced)

    // MARK: - Shadows

    static let shadowSmall  = ShadowStyle.drop(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    static let shadowMedium = ShadowStyle.drop(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
    static let shadowLarge  = ShadowStyle.drop(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)

    // MARK: - Animation Presets

    static let springSnappy = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let springBouncy = Animation.spring(response: 0.45, dampingFraction: 0.65)
    static let easeSmooth   = Animation.easeInOut(duration: 0.25)
    static let easeSlow     = Animation.easeInOut(duration: 0.5)
}

// MARK: - View Modifiers

extension View {
    /// Applies the standard HomeHub elevated card style with glassmorphism.
    func hhGlassCard(cornerRadius: CGFloat = HHTheme.cornerLarge) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(HHTheme.stroke, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
    }

    /// Applies the standard HomeHub elevated card with solid background.
    func hhCard(cornerRadius: CGFloat = HHTheme.cornerMedium) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(HHTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(HHTheme.stroke, lineWidth: 1)
            )
    }

    /// Smooth press-down animation for interactive cards/buttons.
    func hhPressEffect(isPressed: Bool) -> some View {
        self
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .opacity(isPressed ? 0.9 : 1.0)
            .animation(HHTheme.springSnappy, value: isPressed)
    }

    /// Pulsing glow border for active/streaming states.
    func hhGlowBorder(isActive: Bool, color: Color = HHTheme.accent) -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                    .stroke(color.opacity(isActive ? 0.6 : 0), lineWidth: 2)
                    .blur(radius: isActive ? 4 : 0)
            )
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isActive)
    }
}
