import SwiftUI

struct MessageComposerView: View {
    @EnvironmentObject private var settings: SettingsService
    @Binding var draft: String
    let isStreaming: Bool
    let canSend: Bool
    /// Estimated fraction of the context window used (0.0–1.0).
    /// Drives a subtle colour bar shown above the input once usage exceeds 50%.
    let tokenFill: Double
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Context usage bar — visible only when context is getting full
            if tokenFill > 0.5 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(contextBarColor)
                        .frame(width: geo.size.width * tokenFill)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeInOut(duration: 0.3), value: tokenFill)
                }
                .frame(height: 2)
            }

            Divider().overlay(HHTheme.stroke)

            HStack(alignment: .bottom, spacing: HHTheme.spaceM) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .font(HHTheme.body)
                    .padding(.horizontal, HHTheme.spaceL)
                    .padding(.vertical, HHTheme.spaceM)
                    .background(
                        RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                            .fill(HHTheme.surface)
                    )

                if isStreaming {
                    Button {
                        HHHaptics.impact(.medium, enabled: settings.current.haptics)
                        onCancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(HHTheme.danger)
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        HHHaptics.impact(.light, enabled: settings.current.haptics)
                        onSend()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(canSend ? HHTheme.accent : HHTheme.textSecondary.opacity(0.3))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, HHTheme.spaceL)
            .padding(.vertical, HHTheme.spaceM)
        }
        .background(HHTheme.canvas)
    }

    private var contextBarColor: Color {
        if tokenFill > 0.9 { return HHTheme.danger }
        if tokenFill > 0.75 { return HHTheme.warning }
        return HHTheme.accent.opacity(0.6)
    }
}
