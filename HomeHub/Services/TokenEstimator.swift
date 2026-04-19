import Foundation

/// Shared façade over `TokenEstimating` for callers that just need a
/// rough token count. UI badges, the in-composer context-fill bar,
/// and orchestration heuristics (e.g. summarisation triggers) all
/// route through here so the estimator lives in one place and the
/// app stays internally consistent.
///
/// For per-prompt budgeting (chat-template overhead, history trim)
/// use `PromptTokenBudgeter` instead — the helpers here intentionally
/// ignore per-message envelope tokens and just count content.
enum TokenEstimator {

    /// Process-wide estimator instance. Reads remain valid even when
    /// crossed across actor hops because `HeuristicTokenEstimator` is
    /// a value-type with no mutable state.
    static let shared: any TokenEstimating = HeuristicTokenEstimator()

    /// Estimated token count for a single string.
    static func tokens(in text: String) -> Int {
        shared.tokens(in: text)
    }

    /// Estimated token count summed across `messages` (content only).
    static func tokens(in messages: [Message]) -> Int {
        messages.reduce(0) { $0 + shared.tokens(in: $1.content) }
    }

    /// Fraction of `contextLength` filled by `messages`, clamped to 0–1.
    /// Returns `0` when `contextLength <= 0` so callers don't have to
    /// guard against a zero-budget runtime themselves.
    static func contextFill(messages: [Message], contextLength: Int) -> Double {
        guard contextLength > 0 else { return 0 }
        return min(Double(tokens(in: messages)) / Double(contextLength), 1.0)
    }
}
