import Foundation

// MARK: - StreamCacheBox

/// Mutable box used to pass the final prompt-token array out of the
/// detached Task inside `LlamaContextHandle.stream()`.
///
/// The generation Task writes `finalPromptTokens` on every completion
/// path (normal finish, EOS, stop-sequence, cancellation, error) just
/// before calling `continuation.finish(...)`. The caller
/// (`LlamaCppRuntime.generate()`) reads it after `await`ing the full
/// stream to update the per-conversation KV-cache session record.
///
/// `@unchecked Sendable`: the write always happens-before the
/// `continuation.finish()` that wakes the awaiting Task, so the read
/// sees a fully-written value without a lock. The pattern is the same as
/// the established `GenerationCancellationToken`.
final class StreamCacheBox: @unchecked Sendable {
    /// Tokens decoded in the prompt phase of the most recent generation.
    /// Empty until the generation Task writes it at completion.
    var finalPromptTokens: [Int32] = []
}

// MARK: - ConversationRuntimeSession

/// Records the token sequence that is currently resident in the KV cache
/// for a single conversation.
///
/// When the next generation starts for the same conversation, the runtime
/// computes the longest common prefix between `cachedPromptTokens` and the
/// new prompt tokens. If the prefix covers more than `minReuseRatio` of the
/// new prompt, `llama_kv_cache_clear` is skipped and prompt evaluation
/// begins at `prefixLen` — reusing the already-decoded prefix for free.
///
/// ## Lifecycle
/// - Created / updated in `LlamaCppRuntime.generate()` after each stream.
/// - Keyed by `conversationID` in `LlamaRuntimeActor.sessions`.
/// - Entire map cleared in `LlamaRuntimeActor.unload()` — a freshly loaded
///   model starts with an empty KV cache.
struct ConversationRuntimeSession: Sendable, Equatable {

    let conversationID: UUID

    /// Token sequence that is currently resident in the KV cache.
    /// Updated after every generation turn.
    var cachedPromptTokens: [Int32]

    // MARK: - Prefix matching

    /// The fraction of the new prompt that must be covered by the cached
    /// prefix before we bother skipping the clear. Below this threshold the
    /// savings are too small to justify the added complexity.
    static let minReuseRatio: Double = 0.5

    /// Returns the length of the longest common prefix between
    /// `cachedPromptTokens` and `tokens`.
    func commonPrefixLength(with tokens: [Int32]) -> Int {
        var i = 0
        while i < cachedPromptTokens.count && i < tokens.count
                && cachedPromptTokens[i] == tokens[i] {
            i += 1
        }
        return i
    }
}
