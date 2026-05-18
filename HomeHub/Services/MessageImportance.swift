import Foundation

/// Heuristic importance scoring for chat messages.
///
/// **Why it exists.** The token budgeter trims oldest-first when the
/// conversation grows past the context window. That's the safe default
/// — recent context is usually what the model needs to answer the
/// current turn. But "important" old messages (user-stated preferences,
/// concrete decisions, code snippets the user pasted) get lost the same
/// way as throwaway chitchat ("ok", "thanks").
///
/// The `ConversationRecallService` already pulls *semantically similar*
/// old messages back into context when the current query touches them.
/// `MessageImportance` is the complementary signal: it surfaces
/// intrinsically high-value messages even when the query doesn't
/// semantically match — useful for the model to remember "the user
/// said they're a vegetarian" 40 turns later when food comes up in
/// a tangential way.
///
/// **Cost.** Pure function over `Message.content`; no embeddings, no
/// inference, no actor hops. Safe to call on the hot path.
///
/// **Calibration.** Scores are in [0, 1]; thresholds are documented
/// per call site. A score of `0.0` means "throwaway — drop first";
/// `1.0` means "always include if possible". The scoring is
/// intentionally simple — we'd rather have a debuggable heuristic
/// than a black-box classifier the user can't reason about.
struct MessageImportance {

    /// Per-message importance score. Higher = more worth keeping in
    /// context when the budgeter is forced to trim.
    ///
    /// Signals (additive, clamped to [0, 1]):
    ///   - **Length**: longer messages convey more information.
    ///     `0.0` for empty, `0.3` for a long paragraph.
    ///   - **User-authored**: user messages encode preferences and
    ///     constraints; assistant messages can usually be regenerated.
    ///     `+0.15` for user.
    ///   - **Code fence**: contains "```" — technical detail that's
    ///     hard for the model to reconstruct. `+0.25`.
    ///   - **Declaration markers**: phrases like "I am", "I'm",
    ///     "my name is", "remember that", "always", "never" —
    ///     durable user-state statements. `+0.2`.
    ///   - **Numeric / capitalized tokens**: dates, IDs, proper nouns.
    ///     `+0.1` if any detected.
    ///   - **Trivial-reply penalty**: short messages matching the
    ///     "ok / thanks / yes" set get a flat low score regardless
    ///     of other signals.
    static func score(_ message: Message) -> Double {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return 0.0 }

        // Trivial-reply short-circuit. These messages add nothing the
        // model needs to remember later; even a 1.0 from other signals
        // wouldn't make "ok" worth a context slot.
        let lowered = content.lowercased()
        if content.count <= 10 {
            let trivial: Set<String> = [
                "ok", "okay", "yes", "no", "yep", "nope", "díky", "diky",
                "thanks", "thx", "sure", "ano", "ne", "k", "kk", "👍", "🙏"
            ]
            if trivial.contains(lowered) { return 0.05 }
        }

        var score = 0.0

        // Length signal — saturating at ~400 chars (one solid paragraph).
        // Linear ramp keeps the scoring predictable; longer messages
        // beyond this point don't get extra credit (a 5000-char dump
        // isn't 12× more important than a 400-char one).
        let lengthSignal = min(0.3, Double(content.count) / 400.0 * 0.3)
        score += lengthSignal

        if message.role == .user {
            score += 0.15
        }

        if content.contains("```") {
            score += 0.25
        }

        // Declaration markers — both English and Czech variants of
        // "this is who I am / this is what I want you to know".
        let declarations = [
            "i am ", "i'm ", "my name", "remember that", "always ",
            "never ", "i prefer", "i don't", "i work as",
            "jmenuji se", "jsem ", "vždycky", "vzdycky", "nikdy",
            "preferuju", "pamatuj si", "preferuji"
        ]
        if declarations.contains(where: { lowered.contains($0) }) {
            score += 0.2
        }

        // Numeric / proper-noun signal: at least one digit or at least
        // two capitalised words (proper noun chain like "Steve Jobs").
        let hasDigit = content.contains { $0.isNumber }
        let capWordCount = content
            .split(whereSeparator: { $0.isWhitespace })
            .filter { word in
                guard let first = word.first else { return false }
                return first.isUppercase
            }
            .count
        if hasDigit || capWordCount >= 2 {
            score += 0.1
        }

        return min(1.0, score)
    }

    /// Returns the top-`limit` highest-importance messages from
    /// `candidates`, excluding any IDs in `excludeIDs`. The order of
    /// the returned array preserves the original chronological order
    /// of `candidates` (not similarity-descending) — readability for
    /// downstream prompt rendering, identical to how `ConversationRecallService`
    /// presents its semantic top-K.
    ///
    /// Used by the recall pipeline to top up the L0.6 block with
    /// intrinsically-important dropped messages after the semantic
    /// matches have been chosen.
    static func topImportant(
        from candidates: [Message],
        excluding excludeIDs: Set<UUID>,
        limit: Int,
        minScore: Double = 0.35
    ) -> [Message] {
        guard limit > 0 else { return [] }
        let scored = candidates
            .filter { !excludeIDs.contains($0.id) }
            .map { ($0, score($0)) }
            .filter { $0.1 >= minScore }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)

        // Preserve chronological order in the output.
        let chosen = Set(scored.map(\.id))
        return candidates.filter { chosen.contains($0.id) }
    }
}
