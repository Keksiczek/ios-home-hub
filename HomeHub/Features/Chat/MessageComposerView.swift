import SwiftUI

struct MessageComposerView: View {
    @EnvironmentObject private var settings: SettingsService
    @Binding var draft: String
    let isStreaming: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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
}
