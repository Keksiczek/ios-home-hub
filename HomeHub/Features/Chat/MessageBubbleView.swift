import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    /// Called when the user picks "Regenerate" from the context menu.
    /// Pass `nil` for all messages except the last completed assistant reply.
    var onRegenerate: (() -> Void)? = nil
    /// Called when the user picks "Delete" from the context menu. Pass
    /// `nil` on read-only views (e.g. previews) to hide the action.
    var onDelete: (() -> Void)? = nil

    /// Content with chat-template control tokens (`<start_of_turn>`,
    /// `<|eot_id|>`, `</s>` …) removed. Applied at render time so the raw
    /// string in storage stays lossless for debugging, but the user never
    /// sees leaked control markers in their bubbles.
    private var displayContent: String {
        ChatTextSanitizer.strip(message.content)
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                header

                if displayContent.isEmpty && message.status == .streaming {
                    TypingIndicator()
                } else if message.role == .assistant {
                    // Generative UI support — intercepts <Widget:...> and falls back to markdown
                    WidgetRenderer(rawContent: displayContent)
                } else {
                    Text(displayContent)
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
                    UIPasteboard.general.string = displayContent
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

                if let onDelete {
                    Divider()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    // MARK: - Header (role + timestamp)

    private var header: some View {
        HStack(spacing: 6) {
            Text(roleLabel)
                .font(HHTheme.caption.weight(.semibold))
                .foregroundStyle(roleLabelColor)
            Text(Self.timestampFormatter.string(from: message.createdAt))
                .font(HHTheme.caption.monospacedDigit())
                .foregroundStyle(HHTheme.textSecondary)
        }
        .opacity(0.9)
    }

    private var roleLabel: String {
        switch message.role {
        case .user:      return "You"
        case .assistant: return "Assistant"
        case .system:    return "System"
        }
    }

    private var roleLabelColor: Color {
        message.role == .user ? .white.opacity(0.85) : HHTheme.textSecondary
    }

    /// Short per-turn timestamp — hour + minute is enough for a chat log.
    /// Full date is already visible in the conversation-list preview.
    private static let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

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
