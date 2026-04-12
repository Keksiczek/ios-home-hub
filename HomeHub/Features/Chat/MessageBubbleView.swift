import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    /// Called when the user picks "Regenerate" from the context menu.
    /// Pass `nil` for all messages except the last completed assistant reply.
    var onRegenerate: (() -> Void)? = nil

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 4) {
                if message.content.isEmpty && message.status == .streaming {
                    TypingIndicator()
                } else if message.role == .assistant {
                    // Generative UI support — intercepts <Widget:...> and falls back to markdown
                    WidgetRenderer(rawContent: message.content)
                } else {
                    Text(message.content)
                        .font(HHTheme.body)
                        .foregroundStyle(textColor)
                        .textSelection(.enabled)
                }

                if message.status == .failed {
                    Label("Failed", systemImage: "exclamationmark.triangle.fill")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.warning)
                } else if message.status == .cancelled {
                    Text("Stopped")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                }
            }
            .padding(.horizontal, HHTheme.spaceL)
            .padding(.vertical, HHTheme.spaceM)
            .background(
                RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                if let onRegenerate {
                    Divider()
                    Button {
                        onRegenerate()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var background: Color {
        switch message.role {
        case .user:      return HHTheme.accent
        case .assistant: return HHTheme.surface
        case .system:    return HHTheme.surfaceRaised
        }
    }

    private var strokeColor: Color {
        message.role == .user ? .clear : HHTheme.stroke
    }

    private var textColor: Color {
        message.role == .user ? .white : HHTheme.textPrimary
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(HHTheme.textSecondary.opacity(phase == i ? 0.8 : 0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .onAppear {
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await MainActor.run { phase = (phase + 1) % 3 }
                }
            }
        }
    }
}
