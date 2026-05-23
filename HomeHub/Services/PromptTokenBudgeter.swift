import Foundation
import NaturalLanguage

// MARK: - TokenEstimating

/// Estimates how many tokens a string will occupy once a specific model
/// tokenises it. Exists as a protocol so we can plug in a real BPE
/// tokenizer later (EPIC 6) without churning call sites.
///
/// All implementations must be deterministic: the same input always
/// produces the same count. The return value is always `>= 0`.
///
/// Most callers should not depend on this protocol directly — use the
/// `TokenEstimator` namespace for the shared app-wide heuristic.
protocol TokenEstimating: Sendable {
    /// Fast token estimate (hot path — used per-streaming-token).
    func tokens(in text: String) -> Int

    /// More accurate estimate for single-shot use (e.g. prompt assembly).
    /// Default implementation delegates to `tokens(in:)`. Override for
    /// better precision on short texts where the NLTokenizer overhead is
    /// acceptable.
    func estimateAccurate(text: String) -> Int
}

extension TokenEstimating {
    func estimateAccurate(text: String) -> Int { tokens(in: text) }
}

// MARK: - HeuristicTokenEstimator

/// Character-class-aware token estimator.
///
/// Replaces the old `chars * 0.35` heuristic (which under-counted code,
/// JSON, and non-Latin text by 2–3x) with a Unicode-scalar bucket model.
/// Each scalar contributes a tokens-per-character weight based on the
/// script and character class it belongs to. Weights are calibrated
/// against empirical counts from the BPE tokenizer family shared by Llama
/// 3 / Phi / Qwen / Gemma — the same vocabulary both MLX and llama.cpp
/// load — for typical conversational English, code, JSON, CJK, and emoji
/// inputs.
///
/// ## Accuracy
/// On internal fixtures the heuristic is within ±15% of the true token
/// count for English prose, code, and JSON; within ±30% for CJK; and
/// systematically over-counts emoji-heavy text (acceptable for a budget
/// guard — we'd rather trim slightly too much than overflow the context).
///
/// ## Why not call the real tokenizer?
/// Both backend tokenizers (MLX's `Tokenizers.encode`, llama.cpp's
/// `llama_tokenize`) are fast but require an actively-loaded context.
/// Prompt assembly needs to estimate tokens before the context is built,
/// runs on the main actor during UI updates, and must return synchronously
/// for every assembled prompt — calling into C++ synchronously from the
/// main actor is something we're avoiding until EPIC 6 introduces a
/// dedicated tokenizer actor.
struct HeuristicTokenEstimator: TokenEstimating {

    func tokens(in text: String) -> Int {
        if text.isEmpty { return 0 }
        var total: Double = 0
        for scalar in text.unicodeScalars {
            total += weight(for: scalar)
        }
        return max(1, Int(total.rounded(.up)))
    }

    /// NLTokenizer-based estimate for texts up to 500 characters.
    /// Uses `.word` tokenization as a proxy for BPE tokens: on English prose
    /// this correlates well (± ~10%); on code and CJK the heuristic fallback
    /// is used instead because NLTokenizer's word unit is not representative.
    /// For longer texts the scalar-weight path is faster and accurate enough.
    func estimateAccurate(text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        guard text.count <= 500 else { return tokens(in: text) }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        // NLTokenizer word count underestimates punctuation-heavy or
        // code-heavy strings; blend with the scalar-weight estimate
        // (take the max) to stay conservative for budget purposes.
        return max(count, tokens(in: text))
    }

    /// Tokens-per-character weight for one Unicode scalar.
    ///
    /// The bucket boundaries correspond to blocks where BPE tokenisers
    /// behave consistently. Adding a new script? Pick the bucket that
    /// most closely matches its tokens-per-character ratio rather than
    /// introducing a new one.
    private func weight(for scalar: Unicode.Scalar) -> Double {
        let v = scalar.value
        switch v {
        // CJK, Hiragana, Katakana, Hangul — typically one token per character.
        case 0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF:   // Hangul Syllables
            return 1.0

        // Emoji and pictographs — BPE tokenisers typically use 2+ tokens
        // per emoji, especially for multi-scalar ZWJ sequences. Over-
        // count deliberately so emoji-heavy prompts don't blow the budget.
        case 0x1F000...0x1FFFF, // Emoji blocks
             0x2600...0x27BF:   // Misc symbols + Dingbats
            return 2.0

        // ASCII digits, letters, and space — the cheapest tokens,
        // roughly four characters per token for well-known vocabularies.
        case 0x20,              // space
             0x30...0x39,       // 0-9
             0x41...0x5A,       // A-Z
             0x61...0x7A:       // a-z
            return 0.25

        // Control characters (newline, tab, etc.) — tokenisers merge
        // these aggressively; treat as nearly free.
        case 0x00...0x1F, 0x7F:
            return 0.125

        // ASCII punctuation and symbols — BPE tokenisers usually keep
        // one token per character; a few merged digraphs (`.\n`, `, `,
        // `: `) sneak in but the dominant case is 1:1. Earlier 1/2.8
        // (≈ 0.36) under-counted punctuation-dense Czech prose because
        // diacritic-letter+punct sequences split aggressively. 0.5 is
        // the same anchor we use for non-ASCII scripts — slightly
        // over-counts on pure English but errs on the safe side for
        // mixed-language inputs, which is the right direction for a
        // budget guard.
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E:
            return 0.5

        // Latin-Extended (covers Czech, Polish, Hungarian, German
        // umlauts) — ASCII letters with diacritics. Llama 3 / Qwen /
        // Gemma BPE tokenizers split most diacritic-bearing words into
        // 1.5–2 chars/token (more aggressive than plain ASCII because
        // the diacritic forms aren't always in the vocab). Czech "ě"
        // / "ř" / "ů" routinely split into 2 BPE pieces. Weight 0.5
        // (= 2 chars/token) over-estimates by ~10–20 % for typical
        // mixed Czech prose, which is the safe direction for a budget
        // guard — under-estimating Czech caused real-world prompt
        // overruns on Llama 3.2 3B with a 2 048-token context.
        case 0x80...0x024F:      // Latin-1 Supplement + Latin-Extended-A/B
            return 0.5

        // Everything else — Cyrillic, Greek, Arabic, etc.
        // BPE vocabularies tokenise these around 2 chars/token.
        default:
            return 0.5
        }
    }
}

// MARK: - PromptBudgetReport

/// Snapshot of how a single assembled prompt fit inside the model's
/// context budget.
///
/// Emitted by `PromptAssemblyService` after every `build(from:)` call
/// and surfaced in Developer Diagnostics so we can verify per-family
/// budgeting without a debugger attached.
///
/// ## Why not just log?
/// Structured reports compose: the diagnostics panel can render them,
/// the telemetry channel can attach them to a request ID, and tests can
/// assert on exact section sizes without parsing log lines.
struct PromptBudgetReport: Sendable, Equatable {

    /// A single labelled contribution to the prompt's token count.
    /// Sections are informational — the runtime sees one contiguous
    /// `RuntimePrompt`; the split is for humans reading diagnostics.
    struct Section: Sendable, Equatable {
        let name: String
        let tokens: Int
    }

    /// Canonical lowercase model family (e.g. `"llama"`, `"default"`).
    let family: String

    /// Which prompt mode produced this report.
    let mode: PromptMode

    /// Ordered contributions that make up the prompt.
    let sections: [Section]

    /// Number of recent-history messages that survived the budget trim.
    let historyMessagesKept: Int

    /// Number of recent-history messages dropped because of the budget.
    /// `0` when the history fit comfortably.
    let historyMessagesDropped: Int

    /// Tokens the model reserves for its own generation output.
    /// Included in the report so diagnostics can reason about whether
    /// the prompt + reserve stays under the model's context length.
    let generationReserveTokens: Int

    /// Sum of all section token counts. Use this to compare against
    /// `model.contextLength - generationReserveTokens` when auditing
    /// a prompt for budget pressure.
    var totalPromptTokens: Int {
        sections.reduce(0) { $0 + $1.tokens }
    }

    /// Human-readable, multi-line rendering for diagnostics UI and logs.
    var summary: String {
        var lines: [String] = ["Prompt budget (\(family), \(mode.rawValue)):"]
        for section in sections {
            lines.append("  \(section.name): \(section.tokens) tokens")
        }
        lines.append("  history kept: \(historyMessagesKept)")
        lines.append("  history dropped: \(historyMessagesDropped)")
        lines.append("  generation reserve: \(generationReserveTokens)")
        lines.append("  total prompt: \(totalPromptTokens)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - PromptTokenBudgeter

/// Token-aware prompt budget policy for a specific model family.
///
/// Replaces the old `chars <= tokenBudget / 0.35` filter with an
/// explicit estimator. The budgeter also applies the family's
/// `messageTokenOverhead` (chat-template wrappers like Llama 3 header
/// IDs or Gemma turn tokens) so we don't under-estimate long-history
/// chats where the envelope tokens start to dominate.
///
/// ## Responsibilities
/// 1. Estimate tokens for raw text and whole chat messages.
/// 2. Trim a list of `Message` values to fit the profile's history
///    token budget, dropping oldest messages first.
///
/// ## What it deliberately doesn't do
/// - Doesn't build the actual `RuntimePrompt` — that's
///   `PromptAssemblyService`'s job.
/// - Doesn't call the real tokenizer — estimation only. The C++
///   bridge is the last-line budget guard.
struct PromptTokenBudgeter: Sendable {

    let profile: ModelCapabilityProfile
    let estimator: TokenEstimating

    init(
        profile: ModelCapabilityProfile,
        estimator: TokenEstimating = HeuristicTokenEstimator()
    ) {
        self.profile = profile
        self.estimator = estimator
    }

    /// Tokens for a raw string (no chat-template overhead).
    func tokens(in text: String) -> Int {
        estimator.tokens(in: text)
    }

    /// Accurate token estimate for a single piece of text (prompt assembly
    /// use — called once per turn, not per streaming token).
    func tokensAccurate(in text: String) -> Int {
        estimator.estimateAccurate(text: text)
    }

    /// Tokens for a chat message, including the per-message envelope
    /// tokens added by the model's chat template.
    func tokensForMessage(content: String) -> Int {
        estimator.tokens(in: content) + profile.messageTokenOverhead
    }

    /// Keeps as many messages as fit inside the profile's
    /// `safeHistoryTokenBudget` using an anchor + recency strategy:
    ///
    /// 1. The first two messages are always kept ("anchors") — they
    ///    establish the conversation topic and the persona expectations
    ///    the user set at turn 0. Losing them in long threads causes the
    ///    model to drift off-topic or forget the user's initial framing.
    /// 2. The remaining budget is filled by the most-recent messages
    ///    (newest first), so the immediate context is never starved.
    /// 3. Messages in the middle are dropped when the budget is tight —
    ///    those are the least load-bearing for continuity.
    ///
    /// Falls back to pure recency when the anchors alone exceed the
    /// budget (extremely tight profile + very long opening messages).
    ///
    /// - Returns: `kept` contains the surviving messages in their
    ///   original order; `dropped` counts how many were removed.
    func trimHistory(_ messages: [Message]) -> (kept: [Message], dropped: Int) {
        guard !messages.isEmpty else { return ([], 0) }
        let budget = profile.safeHistoryTokenBudget

        // Fast path: everything fits.
        let totalCost = messages.reduce(0) { $0 + tokensForMessage(content: $1.content) }
        if totalCost <= budget { return (messages, 0) }

        // Anchor phase: reserve cost for the first two messages.
        let anchorSlice = messages.prefix(2)
        let anchorCost = anchorSlice.reduce(0) { $0 + tokensForMessage(content: $1.content) }

        // Fallback to pure-recency when anchors are too expensive.
        guard anchorCost < budget else {
            var running = 0
            var keptReversed: [Message] = []
            for message in messages.reversed() {
                let cost = tokensForMessage(content: message.content)
                if running + cost > budget { break }
                running += cost
                keptReversed.append(message)
            }
            let kept = Array(keptReversed.reversed())
            return (kept, messages.count - kept.count)
        }

        // Recency phase: fill remaining budget from the tail (skipping anchors).
        let tail = Array(messages.dropFirst(anchorSlice.count))
        let remainingBudget = budget - anchorCost
        var running = 0
        var recentReversed: [Message] = []
        for message in tail.reversed() {
            let cost = tokensForMessage(content: message.content)
            if running + cost > remainingBudget { break }
            running += cost
            recentReversed.append(message)
        }
        let recent = Array(recentReversed.reversed())
        let kept = Array(anchorSlice) + recent
        return (kept, messages.count - kept.count)
    }
}
