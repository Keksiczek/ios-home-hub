import Foundation

/// Actor-backed LRU cache that fronts another `WebSearchEngine`.
///
/// Memoises `(query → results)` so repeated lookups inside the cache
/// window are network-free and bandwidth-free. Two upstream wins:
///
///   * **Bandwidth + rate-limits.** DDG Lite scrapes start to 429 if
///     the same query fires several times a second; SearXNG instances
///     also rate-limit. The agentic loop occasionally retries the same
///     search (model reformulates, then reverts) — without caching
///     every retry costs a network round-trip + risks a ban.
///   * **Latency.** A cache hit returns in ~hundreds of microseconds.
///     Even an 80 ms DDG response feels sluggish next to that, and
///     the user-perceived "is the chat thinking?" latency shrinks
///     proportionally when the model double-checks a recent query.
///
/// **Threading model.** Implemented as an `actor` so the cache state
/// is serialised by construction — callers from any isolation domain
/// (main-actor `ConversationService`, non-isolated runtime tasks,
/// background skill executors) all funnel through the actor's
/// implicit queue. No manual locks, no `Sendable` gymnastics on the
/// stored array.
///
/// Conforming to the `WebSearchEngine` protocol means the rest of the
/// app (`WebSearchSkill`, `FallbackWebSearchEngine`) keeps talking to
/// the same interface — caching is purely a wiring-time decision in
/// `AppContainer.makeWebSearchEngine`.
actor CachingWebSearchEngine: WebSearchEngine {
    /// Single cache row. `Date` here is the *creation* time, not the
    /// expiry, because expiry depends on the TTL set at engine
    /// construction — keeping it generative lets a future tuning
    /// change the TTL without invalidating live cache entries.
    private struct Entry {
        let query: String
        let results: [SearchResult]
        let createdAt: Date
    }

    /// Wrapped engine — the one that actually talks to the network.
    /// Held as an `any WebSearchEngine` (existential) so the cache
    /// can sit in front of any conforming engine: DDG Lite, SearXNG,
    /// fallback chains, or even another `CachingWebSearchEngine`
    /// (a pointless config, but composable nonetheless).
    private let upstream: any WebSearchEngine

    /// How long a cached entry stays fresh. 15 min is the sweet spot
    /// for "did the user just ask the same question?" without
    /// returning stale weather/price/news data on follow-ups within
    /// the same conversation. Bumping this risks serving an answer
    /// the user already knows is wrong; shrinking it kills the
    /// hit-rate gains.
    private let ttl: TimeInterval

    /// Maximum cache rows retained. Older entries fall off the front
    /// when this is exceeded. 50 ≈ ten 5-message conversations of
    /// mixed search queries — generous enough to cover normal chat
    /// pacing, small enough to stay <1 MB even with chunky snippet
    /// arrays.
    private let capacity: Int

    /// Ordered newest-last. Linear scan on lookup is fine at this
    /// capacity (≤ 50 entries) — the alternative (Dictionary + DLL)
    /// adds a lot of code for sub-microsecond gains the user can't
    /// perceive. Array operations are also the cheapest for the
    /// "evict oldest" case (drop front).
    private var entries: [Entry] = []

    /// Display name of the engine chain — surfaced in the model's
    /// observation. Forwarded from the upstream so the cache layer is
    /// transparent to the LLM's citation rendering. "DuckDuckGo"
    /// stays "DuckDuckGo" whether or not a cache fronts it.
    nonisolated var displayName: String { upstream.displayName }

    init(
        upstream: any WebSearchEngine,
        ttl: TimeInterval = 15 * 60,
        capacity: Int = 50
    ) {
        self.upstream = upstream
        self.ttl = ttl
        self.capacity = capacity
    }

    /// Cache-key-only normaliser. Two queries that differ in case or
    /// surrounding whitespace are the same lookup as far as the
    /// network goes — collapse them so a model that reformulates
    /// "Weather Prague" / " weather prague " still hits the cache.
    private static func canonicalKey(for query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func search(query: String) async -> [SearchResult] {
        let key = Self.canonicalKey(for: query)
        guard !key.isEmpty else { return [] }
        let now = Date()

        // Lookup + lazy-evict expired entries in one pass. Walking
        // newest-first is faster on hits (LRU tends to be hot at the
        // tail) but newest-last keeps the eviction-by-prefix-drop
        // path trivial — we accept the slightly slower hit lookup.
        if let hitIndex = entries.firstIndex(where: { $0.query == key }) {
            let hit = entries[hitIndex]
            let age = now.timeIntervalSince(hit.createdAt)
            if age < ttl {
                // Promote to tail (most-recently-used). Removing then
                // appending preserves the rest of the ordering at the
                // cost of one array shift; benchmarks at n=50 put
                // this at ~1 µs which the model-side processing
                // dwarfs in any case.
                entries.remove(at: hitIndex)
                entries.append(hit)
                HHLog.tool.debug("WebSearch cache hit: \(key, privacy: .public) age=\(Int(age), privacy: .public)s")
                return hit.results
            } else {
                // Expired — drop and fall through to refetch. The
                // old entry is gone from the array so we don't
                // re-evaluate it on the next miss-path either.
                entries.remove(at: hitIndex)
                HHLog.tool.debug("WebSearch cache expired: \(key, privacy: .public) age=\(Int(age), privacy: .public)s")
            }
        }

        // Cache miss — fetch from upstream. We deliberately do NOT
        // hold the actor's serialisation across the network call:
        // `await` here suspends the actor and lets other queries
        // (cache hits for unrelated questions, mutations from
        // expiry sweeps) run while this one is in flight.
        //
        // Trade-off: two concurrent misses for the *same* query
        // will both hit upstream. That's intentional — coalescing
        // would need a continuation table and a single in-flight
        // task per key, which is a lot of code for a corner case
        // the agentic loop doesn't actually exercise (it serialises
        // tool calls per conversation).
        let results = await upstream.search(query: query)

        // Only cache non-empty results. An empty result is usually
        // either "this query is malformed" (transient — fix on retry)
        // or "upstream is down" (transient — don't pin the failure
        // for 15 min). Caching empties also produces the worst kind
        // of UX: "I searched and got nothing" repeated three times
        // for what was a momentary outage.
        if !results.isEmpty {
            entries.append(Entry(query: key, results: results, createdAt: now))
            if entries.count > capacity {
                // Drop the oldest. Removing from the front is O(n)
                // but n is bounded at 50 and this only fires on
                // overflow, not on every write.
                entries.removeFirst(entries.count - capacity)
            }
        }
        return results
    }

    // MARK: - Diagnostics

    /// Snapshot of the current cache size + age range. Used by
    /// DeveloperDiagnostics to surface "is the cache actually
    /// helping?" without leaking the queries themselves (which can
    /// contain personal phrasing).
    func diagnostics() -> (entries: Int, oldestAgeSeconds: Int?, newestAgeSeconds: Int?) {
        guard let first = entries.first, let last = entries.last else {
            return (0, nil, nil)
        }
        let now = Date()
        return (
            entries.count,
            Int(now.timeIntervalSince(first.createdAt)),
            Int(now.timeIntervalSince(last.createdAt))
        )
    }

    /// Wipe the cache. Surfaced via Settings ("Reset web search cache")
    /// for users who want to force-refresh after they know a query
    /// returned stale data. Also handy after a SearXNG URL change so
    /// the previous instance's results don't leak into the new one.
    func clear() {
        entries.removeAll(keepingCapacity: true)
        HHLog.tool.info("WebSearch cache cleared")
    }
}
