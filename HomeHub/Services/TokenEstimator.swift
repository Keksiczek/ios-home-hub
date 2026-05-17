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

    /// Memoised variant for hot UI paths (chat context-fill banner,
    /// token-usage badge). Re-uses the previously computed count for
    /// any message whose `(id, content.count)` tuple matches the
    /// cached entry — which holds for the entire conversation EXCEPT
    /// the in-flight streaming message, whose `content.count` changes
    /// every token. Net cost during streaming: O(streaming-message
    /// length) per call instead of O(total conversation length).
    ///
    /// The cache lives in a class-level `NSCache` so it's automatically
    /// purged under memory pressure (no hand-rolled eviction needed),
    /// and reads are lock-free (NSCache is thread-safe). Keyed by the
    /// message UUID; the cached payload pairs the token count with
    /// the content length it was computed against so a content edit
    /// invalidates the entry on next read.
    static func cachedTokens(in messages: [Message]) -> Int {
        var total = 0
        for message in messages {
            let key = message.id.uuidString as NSString
            if let entry = tokenCountCache.object(forKey: key),
               entry.contentLength == message.content.count {
                total += entry.count
                continue
            }
            let count = shared.tokens(in: message.content)
            tokenCountCache.setObject(
                CachedTokenCount(count: count, contentLength: message.content.count),
                forKey: key
            )
            total += count
        }
        return total
    }

    /// Fraction of `contextLength` filled by `messages`, clamped to 0–1.
    /// Returns `0` when `contextLength <= 0` so callers don't have to
    /// guard against a zero-budget runtime themselves.
    static func contextFill(messages: [Message], contextLength: Int) -> Double {
        guard contextLength > 0 else { return 0 }
        return min(Double(cachedTokens(in: messages)) / Double(contextLength), 1.0)
    }

    // MARK: - Memoisation backing storage

    /// Small NSCache box so we can store the content length alongside
    /// the count — the length acts as a cheap "content has changed"
    /// fingerprint without storing the entire string a second time.
    private final class CachedTokenCount {
        let count: Int
        let contentLength: Int
        init(count: Int, contentLength: Int) {
            self.count = count
            self.contentLength = contentLength
        }
    }
    // NSCache is documented as thread-safe (the underlying ObjC class
    // does its own locking), so the `nonisolated(unsafe)` here matches
    // reality without needing `@MainActor` isolation that would force
    // the chat-bubble call sites through a hop on every render.
    nonisolated(unsafe) private static let tokenCountCache: NSCache<NSString, CachedTokenCount> = {
        let cache = NSCache<NSString, CachedTokenCount>()
        // Cap of 1000 entries — comfortably covers the 50-conversation ×
        // 20-message-each working set with headroom. NSCache evicts LRU
        // automatically when the limit is exceeded OR when iOS issues a
        // memory-pressure notification (it observes UIApplication
        // didReceiveMemoryWarning internally).
        cache.countLimit = 1000
        return cache
    }()
}
