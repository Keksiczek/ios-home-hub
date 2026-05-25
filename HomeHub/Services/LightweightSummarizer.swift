import Foundation

/// Deterministic, LLM-free summary of a message slice.
///
/// The companion `SummarizationService` runs the loaded LLM to produce
/// a paragraph-style recap — high quality, but it needs a model loaded
/// and burns a few hundred ms of inference per turn. There are real
/// situations where that's the wrong trade:
///
///   * **Cold start.** Conversation reload before the model has
///     finished loading. The first turn after a relaunch has no
///     summary at all, so the prompt budget pressure hits at full
///     force on a chat that already had condensed history yesterday.
///   * **Model unloaded.** Background eager-unload (see task #8)
///     can release the active model under memory pressure. Until the
///     user picks a model again, the LLM-backed summariser short-
///     circuits to `nil` and leaves the stale summary in place — or
///     none at all on a fresh slice.
///   * **LLM failure.** Generation errors (kernel entitlement missing,
///     a misbehaving Q4 checkpoint, OOM mid-stream) return `nil`. The
///     current code logs and gives up; the user just loses
///     condensation entirely.
///
/// `LightweightSummarizer` is the safety net for all three. It does
/// no inference — it picks the first user message (anchors the topic),
/// pulls the most recent N user follow-ups, and renders a compact
/// bullet list capped at a configurable byte budget. Far worse quality
/// than the LLM pass, but worlds better than nothing — and crucially
/// it runs in microseconds with zero memory pressure.
///
/// **Strategy** (extractive, not abstractive):
///   1. Skip system messages and empty content.
///   2. Anchor: the **first user message** sets the conversation
///      topic — almost always worth preserving verbatim.
///   3. Tail: the **last `tailUserMessages` user messages** (default 3).
///      Recent user intent matters more than recent assistant prose;
///      assistant turns are usually elaborations of what the user
///      asked, so the user side carries the signal.
///   4. Each item gets truncated to `perItemByteCap` (default 200 B)
///      at a word boundary with "…" suffix.
///   5. Total output capped at `totalByteCap` (default 800 B) — final
///      tail items get dropped if they would exceed it.
///
/// **Output shape** is intentionally distinct from the LLM summariser
/// so logs / debug views can tell them apart at a glance:
///
///     [Auto-recap]
///     • User opened with: "ahoj, jak udělám HomeKit scénu …"
///     • User then asked: "a jak to nasdílím manželce?"
///     • User then asked: "a jde to spustit Siri zkratkou?"
///
/// The `[Auto-recap]` header is the contract — the prompt template
/// can format the block as `"Earlier in this conversation (recap):"`
/// without re-parsing the body. The header is stripped before being
/// concatenated into the prompt; it survives only in `recap()` so
/// debug-diagnostics screens can show the user what was extracted.
enum LightweightSummarizer {

    /// Defaults tuned for the typical 400–2800 token history budget
    /// the app runs with. 800 B is roughly 200 tokens — small enough
    /// to fit comfortably even on tight-memory tiers, large enough to
    /// carry three or four message excerpts at full per-item cap.
    static let defaultPerItemByteCap = 200
    static let defaultTotalByteCap = 800
    static let defaultTailUserMessages = 3

    /// Renders the extractive summary. Returns `nil` when there's
    /// nothing useful to extract (no user messages, all content
    /// empty) so callers can fall through cleanly to a "no summary
    /// yet" path. Never throws and never blocks.
    static func summarize(
        messages: [Message],
        perItemByteCap: Int = defaultPerItemByteCap,
        totalByteCap: Int = defaultTotalByteCap,
        tailUserMessages: Int = defaultTailUserMessages
    ) -> String? {
        let userMessages = messages.filter {
            $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !userMessages.isEmpty else { return nil }

        var items: [String] = []
        let first = userMessages[0]
        items.append("User opened with: \"\(truncate(first.content, byteCap: perItemByteCap))\"")

        // Tail picks the most recent `tailUserMessages` user turns
        // EXCLUDING the anchor we already emitted. Iterate in
        // chronological order so the bullet list reads naturally
        // top-to-bottom (oldest follow-up first).
        let tail = userMessages
            .dropFirst()
            .suffix(tailUserMessages)
        for message in tail {
            items.append("User then asked: \"\(truncate(message.content, byteCap: perItemByteCap))\"")
        }

        // Total-cap enforcement. Build the rendered body line by
        // line and stop when the next item would push us over the
        // total cap. The anchor is always included even if alone it
        // exceeds the budget — a recap with one bullet still beats
        // an empty recap.
        var rendered = "[Auto-recap]"
        for (index, item) in items.enumerated() {
            let next = rendered + "\n• " + item
            if index > 0 && next.utf8.count > totalByteCap {
                break
            }
            rendered = next
        }
        return rendered
    }

    /// Truncates `text` to at most `byteCap` UTF-8 bytes, ending on a
    /// word boundary when possible, with a trailing ellipsis. Mirrors
    /// the truncation behaviour in `FetchPageSkill.htmlToText` so the
    /// two extractive summaries look stylistically consistent.
    private static func truncate(_ text: String, byteCap: Int) -> String {
        let normalised = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalised.utf8.count > byteCap else { return normalised }
        let prefix = normalised.utf8.prefix(byteCap)
        guard var trimmed = String(prefix) else { return normalised }
        if let lastBreak = trimmed.lastIndex(where: { $0 == " " || $0 == "\n" }) {
            trimmed = String(trimmed[..<lastBreak])
        }
        return trimmed + "…"
    }
}
