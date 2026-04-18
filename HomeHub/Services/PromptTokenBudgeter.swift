import Foundation

// MARK: - TokenEstimator

/// Estimates how many tokens a string will occupy once a specific model
/// tokenises it. Exists as a protocol so we can plug in a real BPE
/// tokenizer later (EPIC 6) without churning call sites.
///
/// All implementations must be deterministic: the same input always
/// produces the same count. The return value is always `>= 0`.
protocol TokenEstimator: Sendable {
    func tokens(in text: String) -> Int
}

// MARK: - HeuristicTokenEstimator

/// Character-class-aware token estimator.
///
/// Replaces the old `chars * 0.35` heuristic (which under-counted code,
/// JSON, and non-Latin text by 2–3x) with a Unicode-scalar bucket model.
/// Each scalar contributes a tokens-per-character weight based on the
/// script and character class it belongs to. The weights are calibrated
/// against empirical counts from the llama.cpp BPE tokenizer family for
/// typical conversational English, code, JSON, CJK, and emoji inputs.
///
/// ## Accuracy
/// On internal fixtures the heuristic is within ±15% of the true token
/// count for English prose, code, and JSON; within ±30% for CJK; and
/// systematically over-counts emoji-heavy text (acceptable for a budget
/// guard — we'd rather trim slightly too much than overflow the context).
///
/// ## Why not call the real tokenizer?
/// `llama_tokenize` is fast but requires an actively-loaded context.
/// Prompt assembly needs to estimate tokens before the context is built,
/// runs on the main actor during UI updates, and must return synchronously
/// for every assembled prompt — calling into C++ synchronously from the
/// main actor is something we're avoiding until EPIC 6 introduces a
/// dedicated tokenizer actor.
struct HeuristicTokenEstimator: TokenEstimator {

    func tokens(in text: String) -> Int {
        if text.isEmpty { return 0 }
        var total: Double = 0
        for scalar in text.unicodeScalars {
            total += weight(for: scalar)
        }
        return max(1, Int(total.rounded(.up)))
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

        // ASCII punctuation and symbols — usually one token per
        // character or slightly better; calibrate to ~2.8 chars/token.
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E:
            return 1.0 / 2.8

        // Everything else — Cyrillic, Greek, Latin-Extended, etc.
        // BPE vocabularies tokenise these around 2–3 chars/token.
        default:
            return 0.4
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
    let estimator: TokenEstimator

    init(
        profile: ModelCapabilityProfile,
        estimator: TokenEstimator = HeuristicTokenEstimator()
    ) {
        self.profile = profile
        self.estimator = estimator
    }

    /// Tokens for a raw string (no chat-template overhead).
    func tokens(in text: String) -> Int {
        estimator.tokens(in: text)
    }

    /// Tokens for a chat message, including the per-message envelope
    /// tokens added by the model's chat template.
    func tokensForMessage(content: String) -> Int {
        estimator.tokens(in: content) + profile.messageTokenOverhead
    }

    /// Keeps as many of the most-recent messages as fit inside the
    /// profile's `safeHistoryTokenBudget`. Oldest messages are dropped
    /// first; ordering of the kept messages is preserved.
    ///
    /// - Returns: `kept` contains the surviving messages in their
    ///   original order; `dropped` counts how many were removed.
    func trimHistory(_ messages: [Message]) -> (kept: [Message], dropped: Int) {
        let budget = profile.safeHistoryTokenBudget
        var running = 0
        var keptReversed: [Message] = []
        keptReversed.reserveCapacity(messages.count)

        for message in messages.reversed() {
            let cost = tokensForMessage(content: message.content)
            if running + cost > budget { break }
            running += cost
            keptReversed.append(message)
        }

        let kept = Array(keptReversed.reversed())
        return (kept, messages.count - kept.count)
    }
}
