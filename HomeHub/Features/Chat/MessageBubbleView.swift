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
    /// Called when the user toggles the bookmark on this message via
    /// the context menu. `nil` hides the menu entry (e.g. for the
    /// streaming placeholder where bookmarking partial content
    /// doesn't make sense).
    var onToggleBookmark: (() -> Void)? = nil
    /// `true` for the currently-streaming assistant bubble while the
    /// runtime is still in the prefill phase (no tokens yet). When
    /// `true`, the typing indicator is replaced by a "Čte kontext…"
    /// label so long RAG prefills don't read as a frozen app.
    var isPrefill: Bool = false

    /// Content with chat-template control tokens (`<start_of_turn>`,
    /// `<|eot_id|>`, `</s>` …) AND tool-call envelopes removed. The
    /// envelope removal is presentation-only; storage keeps the raw
    /// `<tool_call>…</tool_call>` so the agentic loop's parser still
    /// finds it. Without this strip the bubble briefly showed the
    /// raw JSON during streaming, which read as garbage to the user.
    private var displayContent: String {
        Self.stripToolEnvelopes(from: ChatTextSanitizer.strip(message.content))
    }

    /// Detected tool call inside the message, used to render a compact
    /// "Running Calculator…" footer chip inside the bubble while the
    /// agentic loop is fetching the observation. Returns `nil` for
    /// plain messages.
    private var detectedToolCall: ToolCallEnvelope? {
        ToolCallEnvelope.parse(from: message.content)
    }

    /// Removes every tool-call envelope variant from `text`. Mirrors
    /// the wrapper list `ToolCallEnvelope.parse` understands so the
    /// display always agrees with what the parser saw.
    private static func stripToolEnvelopes(from text: String) -> String {
        let patterns = [
            "<tool_call>[\\s\\S]*?</tool_call>",
            "<function_call>[\\s\\S]*?</function_call>",
            "<function>[\\s\\S]*?</function>",
            "<tool>[\\s\\S]*?</tool>",
            "\\[TOOL_CALLS\\][\\s\\S]*?\\[/TOOL_CALLS\\]",
            "<\\|python_tag\\|>[\\s\\S]*?(<\\|eom_id\\|>|<\\|eot_id\\|>|$)"
        ]
        var cleaned = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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

                if displayContent.isEmpty && message.status == .streaming && detectedToolCall == nil {
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
                    // Streaming: render plain text. The full markdown parse
                    // (headings, lists, tables, code fences) re-runs on every
                    // single-token edit because `MarkdownContentView` recomputes
                    // its `blocks` from the entire string each invocation — for
                    // a 500-token reply that's O(n²) work over the lifetime of
                    // the stream. Plain text during streaming, full markdown
                    // (incl. WidgetRenderer dispatch) once `.complete` /
                    // `.failed` flips status. Visual cost: code blocks &
                    // headings appear as text mid-stream and "snap" to
                    // formatting on completion — accepted trade-off for the
                    // measurable FPS win on slower devices.
                    if message.status == .streaming {
                        Text(displayContent)
                            .font(HHTheme.body)
                            .foregroundStyle(textColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // Generative UI support — intercepts <Widget:...> and falls back to markdown
                        WidgetRenderer(rawContent: displayContent)
                    }
                } else {
                    Text(displayContent)
                        .font(HHTheme.body)
                        .foregroundStyle(textColor)
                        .textSelection(.enabled)
                }

                // Compact tool-call chip rendered alongside the
                // sanitized prose. Replaces the raw JSON envelope the
                // user would otherwise see while the agentic loop is
                // fetching the observation. The chip stays visible on
                // completed assistant messages too — that way an
                // exported transcript still hints "this turn called a
                // tool" without surfacing the JSON.
                if let call = detectedToolCall, message.role == .assistant {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .imageScale(.small)
                            .foregroundStyle(HHTheme.accent)
                        Text(message.status == .streaming
                             ? "Calling \(call.name)…"
                             : "Called \(call.name)")
                            .font(HHTheme.caption.weight(.semibold))
                            .foregroundStyle(HHTheme.textSecondary)
                    }
                    .padding(.horizontal, HHTheme.spaceS)
                    .padding(.vertical, 4)
                    .background(HHTheme.accent.opacity(0.12), in: Capsule())
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

                if let onToggleBookmark {
                    Button {
                        onToggleBookmark()
                    } label: {
                        Label(
                            message.isBookmarked ? "Remove bookmark" : "Bookmark",
                            systemImage: message.isBookmarked ? "bookmark.slash" : "bookmark"
                        )
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
            // Visible bookmark dot — small enough that it doesn't
            // shift the header layout, but obvious in a scroll-by so
            // users can spot the saved turn without opening a menu.
            if message.isBookmarked {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HHTheme.warning)
                    .accessibilityLabel("Bookmarked")
            }
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
