import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    /// Called when the user picks "Regenerate" from the context menu.
    /// Pass `nil` for all messages except the last completed assistant reply.
    var onRegenerate: (() -> Void)? = nil
    /// Called when the user picks "Delete" from the context menu. Pass
    /// `nil` on read-only views (e.g. previews) to hide the action.
    var onDelete: (() -> Void)? = nil
    /// Called when the user picks "Edit" on one of their own messages.
    /// The handler is responsible for showing an editor, then invoking
    /// `ConversationService.editAndResend(...)` with the new text.
    var onEdit: (() -> Void)? = nil
    /// `true` for the currently-streaming assistant bubble while the
    /// runtime is still in the prefill phase (no tokens yet). When
    /// `true`, the typing indicator is replaced by a "Čte kontext…"
    /// label so long RAG prefills don't read as a frozen app.
    var isPrefill: Bool = false

    /// Content with chat-template control tokens (`<start_of_turn>`,
    /// `<|eot_id|>`, `</s>` …) removed. Applied at render time so the raw
    /// string in storage stays lossless for debugging, but the user never
    /// sees leaked control markers in their bubbles.
    private var displayContent: String {
        ChatTextSanitizer.strip(message.content)
    }

    /// Tool observations are smuggled in as user-role messages (so the
    /// LLM sees them in the next turn) but should render in the chat as
    /// compact "tool result" chips, not as a confusing user bubble.
    private var observation: ToolObservation? {
        ToolObservation.parse(from: message.content)
    }

    var body: some View {
        // Tool observations get a distinct compact chip layout — they're
        // not really "messages" the user sent, even though the runtime
        // smuggles them in under the user role for prompt-shape reasons.
        if let observation {
            ToolResultChip(observation: observation)
                .padding(.horizontal, HHTheme.spaceM)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                header

                if displayContent.isEmpty && message.status == .streaming {
                    if isPrefill {
                        PrefillIndicator()
                    } else {
                        // Decoding phase but no content has streamed yet —
                        // the gap between "first token decoded" and "first
                        // token rendered in this bubble". Pair the typing
                        // dots with a tiny label so the prefill→decode
                        // transition reads as a visible state change, not
                        // an animation glitch.
                        DecodingIndicator()
                    }
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
                    statusLine(label: "Failed", icon: "exclamationmark.triangle.fill", color: HHTheme.warning)
                } else if message.status == .cancelled {
                    statusLine(label: "Stopped", icon: "stop.circle.fill", color: HHTheme.textSecondary)
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

                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit & resend", systemImage: "pencil")
                    }
                }

                if let onRegenerate {
                    Divider()
                    Button {
                        onRegenerate()
                    } label: {
                        Label(regenerateLabel, systemImage: "arrow.clockwise")
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

    /// Label used by the context-menu "regenerate" action. We swap the
    /// wording for failed/cancelled bubbles so the user understands the
    /// menu item is going to recover from the failure, not just re-roll
    /// a perfectly good answer.
    private var regenerateLabel: String {
        switch message.status {
        case .failed:    return "Try again"
        case .cancelled: return "Resume"
        default:         return "Regenerate"
        }
    }

    // MARK: - Status line

    /// Compact "Failed" / "Stopped" label paired with an inline retry
    /// affordance when the parent view supplied an `onRegenerate` handler.
    /// The button surfaces the same action as the context-menu entry but
    /// without the long-press — discoverability matters when the model is
    /// flaky enough that retry is the difference between a usable test
    /// session and giving up.
    @ViewBuilder
    private func statusLine(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: HHTheme.spaceS) {
            Label(label, systemImage: icon)
                .font(HHTheme.caption)
                .foregroundStyle(color)

            if let onRegenerate {
                Button {
                    onRegenerate()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(HHTheme.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(HHTheme.accent)
            }
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

/// Prefill-phase indicator: pulsing brain glyph + "Čte kontext…" label.
/// Shown in place of the typing dots while the runtime is processing the
/// prompt and no tokens have been emitted yet. Visually distinct so users
/// don't mistake a slow prefill for a frozen app.
private struct PrefillIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(HHTheme.textSecondary)
                .opacity(pulse ? 1.0 : 0.4)
            Text("Čte kontext…")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .task {
            pulse = true
        }
        .accessibilityLabel("Reading context")
    }
}

/// Decoding-phase indicator: typing dots + small "Generuje odpověď…"
/// label. Sits in the brief window between the prefill ending and the
/// first decoded token actually rendering into the bubble. Distinct from
/// `PrefillIndicator` (brain icon, "Čte kontext…") so the user can see
/// the phase change instead of guessing whether the app is still alive.
private struct DecodingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            TypingIndicator()
            Text("Generuje odpověď…")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
                .transition(.opacity)
        }
        .accessibilityLabel("Generating reply")
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(HHTheme.textSecondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase == i ? 1.0 : 0.7)
                    .opacity(phase == i ? 1.0 : 0.3)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: phase)
        // `.task` cancels the loop when the bubble leaves the hierarchy —
        // unlike `Timer.scheduledTimer(...)` from .onAppear which would
        // keep firing after the view dismissed.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { return }
                phase = (phase + 1) % 3
            }
        }
    }
}
