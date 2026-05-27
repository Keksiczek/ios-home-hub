import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    /// Memory service used to resolve `message.appliedMemoryFactIDs`
    /// back to live `MemoryFact` rows for the "🧠 Použito X fakt"
    /// chip.
    ///
    /// **Important:** `@EnvironmentObject` raises a fatal error if
    /// the object is missing from the environment. Production
    /// hierarchies inject it at the root in `HomeHubApp` and at
    /// the tab root in `MainTabView`, so every real chat surface
    /// is safe. Xcode canvas previews that render
    /// `MessageBubbleView` directly MUST also call
    /// `.environmentObject(AppContainer.preview().memoryService)`
    /// or they crash on display. See `DashboardView.swift:663` for
    /// the pattern; the same idiom belongs in any
    /// MessageBubbleView preview.
    @EnvironmentObject private var memoryService: MemoryService
    @State private var showingAppliedFacts = false
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
    /// Called when the user taps "Pokračovat" on a length-truncated
    /// assistant reply. `nil` hides the button — the parent view sets
    /// it only on the most recent assistant message whose
    /// `finishReason == "length"`, so this affordance is targeted at
    /// the one bubble where continuation is meaningful.
    var onContinue: (() -> Void)? = nil
    /// `true` for the currently-streaming assistant bubble while the
    /// runtime is still in the prefill phase (no tokens yet). When
    /// `true`, the typing indicator is replaced by a "Čte kontext…"
    /// label so long RAG prefills don't read as a frozen app.
    var isPrefill: Bool = false

    /// Render the follow-up suggestion chips strip below this bubble.
    /// Gated by the parent (ChatDetailView) so only the most recent
    /// completed assistant message shows the strip — old messages
    /// would just clutter the scroll history.
    var showFollowUpSuggestions: Bool = false

    /// Called when the user taps a follow-up suggestion chip.
    /// Receives the suggestion text verbatim; the parent injects it
    /// into the composer's draft. `nil` hides the strip entirely.
    var onFollowUpTap: ((String) -> Void)? = nil

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
    ///
    /// **Perf**: SwiftUI re-evaluates the bubble's `body` on every
    /// streaming token batch (~10× per second). Compiling six
    /// `NSRegularExpression` instances on each call was measurable in
    /// the field (≥3 ms per body eval on iPhone 11). The compiled
    /// regexes are now static — pattern compile happens once at
    /// process start; the per-call cost is only the match scan.
    private static let toolEnvelopeRegexes: [NSRegularExpression] = {
        let patterns = [
            "<tool_call>[\\s\\S]*?</tool_call>",
            "<function_call>[\\s\\S]*?</function_call>",
            "<function>[\\s\\S]*?</function>",
            "<tool>[\\s\\S]*?</tool>",
            "\\[TOOL_CALLS\\][\\s\\S]*?\\[/TOOL_CALLS\\]",
            "<\\|python_tag\\|>[\\s\\S]*?(<\\|eom_id\\|>|<\\|eot_id\\|>|$)"
        ]
        return patterns.compactMap {
            try? NSRegularExpression(
                pattern: $0,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        }
    }()

    private static func stripToolEnvelopes(from text: String) -> String {
        // Fast path: if none of the envelope opening tokens are present,
        // skip the regex pass entirely. The literal scan is
        // O(text length × patterns) with a tiny constant — bails for
        // 99% of streaming intermediate states where the model is
        // mid-paragraph and there's no `<` in the buffer yet.
        if !text.contains("<") && !text.contains("[TOOL_CALLS]") {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var cleaned = text
        for regex in toolEnvelopeRegexes {
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

                // Inline artifact previews. Renders after the text
                // body so the reading order is "prose → produced
                // outputs", matching how a human would scan a reply.
                // Each artifact gets its own row; for image artifacts
                // we lay out a single preview rather than a grid
                // because chat bubbles already cap their width and
                // multi-column inside a narrow bubble looks cramped.
                if let artifacts = message.artifacts, !artifacts.isEmpty {
                    VStack(alignment: .leading, spacing: HHTheme.spaceS) {
                        ForEach(artifacts) { artifact in
                            ArtifactView(artifact: artifact)
                        }
                    }
                    .padding(.top, 4)
                }

                // Compact tool-call chip rendered alongside the
                // sanitized prose. Replaces the raw JSON envelope the
                // user would otherwise see while the agentic loop is
                // fetching the observation. The chip stays visible on
                // completed assistant messages too — that way an
                // exported transcript still hints "this turn called a
                // tool" without surfacing the JSON.
                if let call = detectedToolCall, message.role == .assistant {
                    // Per-tool icon + label via `ToolPresenter`. The
                    // running label is imperative present continuous
                    // ("Hledám na webu…") while the model is mid-call;
                    // it flips to past-tense ("Web search") once the
                    // turn lands, so the persisted bubble reads
                    // naturally in exports and reopened conversations.
                    let style = ToolPresenter.style(for: call.name)
                    HStack(spacing: 6) {
                        Image(systemName: style.systemImage)
                            .imageScale(.small)
                            .foregroundStyle(HHTheme.accent)
                            // Subtle pulse while the call is in flight
                            // — the existing TypingIndicator dots
                            // disappear behind the chip, so the user
                            // needs *some* motion to read this as
                            // "still working" rather than "stuck".
                            .symbolEffect(
                                .pulse,
                                options: .repeating,
                                isActive: message.status == .streaming
                            )
                        // Multi-stage rotating label for tools with
                        // `streamingPhases` (WebSearch, FetchPage).
                        // For single-phase tools and completed turns
                        // we just render a static Text — keeps the
                        // bubble cheap when nothing's animating.
                        if message.status == .streaming, let phases = style.streamingPhases, phases.count > 1 {
                            RotatingPhaseLabel(phases: phases)
                                .font(HHTheme.caption.weight(.semibold))
                                .foregroundStyle(HHTheme.textSecondary)
                        } else {
                            Text(message.status == .streaming
                                 ? style.runningLabel
                                 : style.completedLabel)
                                .font(HHTheme.caption.weight(.semibold))
                                .foregroundStyle(HHTheme.textSecondary)
                        }
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

                // Memory chip: surfaces which user-memory facts the
                // model "saw" when producing this answer. Tappable
                // sheet expands to the actual fact rows. Renders
                // only on completed assistant turns to avoid
                // distracting from the streaming surface. Facts the
                // user deleted since the turn are filtered out at
                // resolve time so the chip count matches what we
                // can actually show.
                if message.role == .assistant,
                   message.status == .complete,
                   let appliedIDs = message.appliedMemoryFactIDs,
                   !appliedIDs.isEmpty {
                    let resolved = resolveAppliedFacts(ids: appliedIDs)
                    if !resolved.isEmpty {
                        appliedMemoryChip(count: resolved.count)
                    }
                }

                // Generation stats footer: "12 tok · 9.4 t/s · 1.3 s".
                // Renders ONLY on completed assistant messages with
                // stats captured. Small + secondary tint so it
                // doesn't compete with the response content; the
                // numbers build user intuition for "which model
                // is fast on my device" without leaving chat.
                if message.role == .assistant,
                   message.status == .complete,
                   let stats = message.generationStats {
                    generationStatsFooter(stats)
                }

                // Follow-up suggestion chips. Render under the most
                // recent completed assistant message (gated by
                // `showFollowUpSuggestions`, set by ChatDetailView
                // for the latest assistant turn only). Static
                // heuristic prompts — cheap, predictable, no extra
                // inference. Tapping injects the text into the
                // composer draft via `onFollowUpTap`.
                if message.role == .assistant,
                   message.status == .complete,
                   showFollowUpSuggestions,
                   onFollowUpTap != nil {
                    followUpSuggestions
                }

                // Length-truncated reply → inline "Pokračovat" affordance.
                // Rendered inside the bubble (not as a status line) so it
                // reads as a continuation of the response rather than an
                // error recovery — the previous content is still useful,
                // we're just offering to extend it.
                if let onContinue, message.wasTruncatedByLength {
                    continueButton(onContinue)
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
                    Label("Kopírovat", systemImage: "doc.on.doc")
                }

                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Label("Upravit a odeslat znovu", systemImage: "pencil")
                    }
                }

                if let onToggleBookmark {
                    Button {
                        onToggleBookmark()
                    } label: {
                        Label(
                            message.isBookmarked ? "Odebrat ze záložek" : "Přidat do záložek",
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
                        Label("Smazat", systemImage: "trash")
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
        case .failed:    return "Zkusit znovu"
        case .cancelled: return "Pokračovat"
        default:         return "Regenerovat"
        }
    }

    // MARK: - Length-truncation continuation

    /// Compact bordered button rendered inside the bubble for replies
    /// the runtime cut off at the max-tokens budget. The accompanying
    /// caption sets the expectation — without it the button reads as
    /// a generic "regenerate" and users wouldn't know whether the
    /// previous content survives. (It does — `ConversationService`
    /// keeps the truncated reply and sends a fresh "Pokračuj." turn.)
    @ViewBuilder
    private func continueButton(_ action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Odpověď byla zkrácena, protože dosáhla limitu tokenů.")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
            Button {
                action()
            } label: {
                Label("Pokračovat", systemImage: "arrow.forward.circle.fill")
                    .font(HHTheme.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(HHTheme.accent)
        }
        .padding(.top, 4)
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
                    Label("Zkusit znovu", systemImage: "arrow.clockwise")
                        .font(HHTheme.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(HHTheme.accent)
            }
        }
    }

    /// Stats footer: "12 tok · 9.4 t/s · 1.3 s". Number formatting:
    ///   * tokens: integer
    ///   * t/s: one decimal (matches the fastest perceptible delta
    ///     for users; sub-decimal precision is noise)
    ///   * seconds: one decimal up to 9.9, then integer (10+ s)
    /// Renders as a small secondary line, not a chip — three numbers
    /// in a row read more naturally as a status line.
    private func generationStatsFooter(_ stats: Message.GenerationStats) -> some View {
        let durationSec = Double(stats.totalDurationMs) / 1000.0
        let durationLabel: String = durationSec < 10
            ? String(format: "%.1f s", durationSec)
            : "\(Int(durationSec.rounded())) s"
        let tpsLabel = String(format: "%.1f t/s", stats.tokensPerSecond)
        return HStack(spacing: 6) {
            Image(systemName: "speedometer")
                .imageScale(.small)
            Text("\(stats.tokensGenerated) tok · \(tpsLabel) · \(durationLabel)")
                .font(.caption2)
        }
        .foregroundStyle(HHTheme.textSecondary)
        .padding(.top, 2)
    }

    /// Static heuristic follow-up prompts. Three reasonable next
    /// moves that work for almost any assistant response:
    ///   1. "Vysvětli detailněji" — depth zoom
    ///   2. "Shrň to do 3 bullet pointů" — compression
    ///   3. "Co bys mi k tomu doporučil?" — opinion / next step
    /// Tap → parent sets composer draft to the chip text, focusing
    /// the keyboard. The user can edit before sending so this isn't
    /// auto-firing a turn — it's a starter, not a shortcut.
    private var followUpSuggestions: some View {
        let prompts = [
            "Vysvětli to detailněji",
            "Shrň to do 3 bullet pointů",
            "Co bys mi k tomu doporučil?"
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HHTheme.spaceS) {
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        HHHaptics.selection(enabled: true)
                        onFollowUpTap?(prompt)
                    } label: {
                        Text(prompt)
                            .font(HHTheme.caption)
                            .foregroundStyle(HHTheme.accent)
                            .padding(.horizontal, HHTheme.spaceM)
                            .padding(.vertical, 6)
                            .background(HHTheme.accent.opacity(0.10), in: Capsule())
                            .overlay(Capsule().stroke(HHTheme.accent.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    /// Resolve `appliedMemoryFactIDs` back to live `MemoryFact` rows.
    /// Drops IDs that no longer exist in the user's memory (deleted
    /// since the turn) so the chip count and the sheet contents
    /// agree. Preserves the original ordering — facts were already
    /// ranked by `MemoryService.relevantFacts` so the order has
    /// semantic meaning we don't want to lose.
    private func resolveAppliedFacts(ids: [UUID]) -> [MemoryFact] {
        let idSet = Set(ids)
        let byID = Dictionary(uniqueKeysWithValues: memoryService.facts.filter { idSet.contains($0.id) }.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// Tappable "🧠 Použito X fakt" chip. Renders below the
    /// completed assistant bubble; tapping opens a sheet listing
    /// the actual fact bodies. Keeps the bubble compact — most
    /// users won't expand it, the chip is a transparency
    /// affordance that pays for itself only when the user wants
    /// to verify what the model "remembered".
    private func appliedMemoryChip(count: Int) -> some View {
        Button {
            // Haptic feedback is opt-in via settings; the bubble
            // doesn't have a settings env binding, so we just
            // pass `enabled: true` — matches the "tap on a button
            // I made" feel users expect. If a future haptics-
            // disabled audit lands, this becomes
            // `settings.current.haptics`.
            HHHaptics.selection(enabled: true)
            showingAppliedFacts = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain.head.profile")
                    .imageScale(.small)
                Text(memoryChipLabel(count: count))
                    .font(HHTheme.caption.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(HHTheme.accent)
            .padding(.horizontal, HHTheme.spaceS)
            .padding(.vertical, 4)
            .background(HHTheme.accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingAppliedFacts) {
            appliedFactsSheet(ids: message.appliedMemoryFactIDs ?? [])
        }
    }

    /// Czech grammar shim — `1 fakt` / `2-4 fakta` / `5+ faktů`
    /// follows the language's small-numbers declension. The default
    /// "X fakt" form sounds robotic; this stays readable across the
    /// realistic 1-15 range memory typically applies per turn.
    private func memoryChipLabel(count: Int) -> String {
        switch count {
        case 1:        return "🧠 Použil 1 fakt"
        case 2, 3, 4:  return "🧠 Použil \(count) fakta"
        default:       return "🧠 Použil \(count) faktů"
        }
    }

    /// Bottom sheet listing the actual fact bodies. Read-only —
    /// editing a fact mid-conversation is a separate flow (the
    /// dedicated MemoryView). The sheet uses a `List` so iOS handles
    /// scrolling + dividers; height auto-fits via
    /// `presentationDetents(.medium, .large)`.
    private func appliedFactsSheet(ids: [UUID]) -> some View {
        let facts = resolveAppliedFacts(ids: ids)
        return NavigationStack {
            List {
                Section {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fact.content)
                                .font(.body)
                            HStack(spacing: 6) {
                                Text(fact.category.rawValue.capitalized)
                                    .font(.caption2)
                                    .foregroundStyle(HHTheme.textSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(HHTheme.stroke, in: Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Co model viděl o tobě při této odpovědi")
                } footer: {
                    Text("Fakta jsou injektovaná do prompt kontextu. Mazat nebo upravovat je můžeš v Nastavení → Paměť.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Použitá fakta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Hotovo") { showingAppliedFacts = false }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
                    .accessibilityLabel("V záložkách")
            }
        }
        .opacity(0.9)
    }

    private var roleLabel: String {
        switch message.role {
        case .user:      return "Ty"
        case .assistant: return "Asistent"
        case .system:    return "Systém"
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
        .accessibilityLabel("Načítám kontext")
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
        .accessibilityLabel("Generuji odpověď")
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

/// Rotating multi-phase label for long-running tool calls. Used by
/// the chat bubble chip to show "Hledám na webu… → Čtu výsledky… →
/// Shrnuju…" while a WebSearch / FetchPage call is in flight, instead
/// of a static "Hledám…" that reads as stuck.
///
/// Phase advances every ~1.6 s. The label crossfades between phases
/// (no horizontal slide — keeps the chip width stable so neighbouring
/// content doesn't reflow on each tick). Driven by `.task`, so the
/// timer cancels automatically when the bubble leaves the hierarchy
/// (e.g. user scrolls away, conversation switched).
///
/// **Style note.** Apple's Settings → Apple Intelligence uses a
/// shimmer gradient sweep on the in-flight "Thinking…" label.
/// We chose the simpler crossfade because it survives older
/// iOS (the gradient mask trick needs `iOS 17` and only renders well
/// on backgrounds with a known fill colour, which our capsule chip
/// doesn't have — capsules sit on whatever the chat bubble's tint
/// is).
private struct RotatingPhaseLabel: View {
    let phases: [String]
    @State private var index: Int = 0

    var body: some View {
        // `.contentTransition(.opacity)` triggers a smooth alpha
        // crossfade between phase strings rather than the default
        // immediate cut. SwiftUI ties the transition to value
        // identity via the inner `Text(...)`, so the animation
        // applies whenever `index` changes.
        Text(phases[index % phases.count])
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: index)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(1600))
                    if Task.isCancelled { return }
                    // Modulo on increment (vs. on read) keeps `index`
                    // bounded for the lifetime of the view —
                    // theoretically a tool call could run long enough
                    // to overflow `Int` if we didn't wrap.
                    index = (index + 1) % max(phases.count, 1)
                }
            }
    }
}
