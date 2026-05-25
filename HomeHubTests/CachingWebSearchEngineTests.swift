import XCTest
@testable import HomeHub

/// Coverage for the LRU + TTL behaviour of `CachingWebSearchEngine`.
/// The cache wraps an arbitrary `WebSearchEngine`, so we drive it with
/// a deterministic stub that counts upstream calls and replays canned
/// results.
final class CachingWebSearchEngineTests: XCTestCase {

    // MARK: - Stub upstream

    /// Counts calls per query, returns canned results. Conforms to the
    /// same protocol the production engines do so it's a drop-in for
    /// the cache's `upstream` slot.
    private final actor StubEngine: WebSearchEngine {
        nonisolated let displayName = "Stub"

        private(set) var callCounts: [String: Int] = [:]
        private var canned: [String: [SearchResult]] = [:]

        func setResults(_ results: [SearchResult], for query: String) {
            canned[query] = results
        }

        func callCount(for query: String) -> Int {
            callCounts[query] ?? 0
        }

        func search(query: String) async -> [SearchResult] {
            callCounts[query, default: 0] += 1
            return canned[query] ?? []
        }
    }

    private func makeHit(_ title: String, _ url: String = "https://example.com/x") -> SearchResult {
        SearchResult(title: title, url: url, snippet: "snippet for \(title)")
    }

    // MARK: - Cache hit behaviour

    func testRepeatedQueryHitsCacheOnSecondCall() async {
        let stub = StubEngine()
        await stub.setResults([makeHit("A")], for: "weather prague")
        let cache = CachingWebSearchEngine(upstream: stub, ttl: 60, capacity: 10)

        _ = await cache.search(query: "weather prague")
        _ = await cache.search(query: "weather prague")

        let count = await stub.callCount(for: "weather prague")
        XCTAssertEqual(count, 1, "Second call must come from cache, not hit upstream")
    }

    func testCaseAndWhitespaceNormalisedToSameKey() async {
        let stub = StubEngine()
        await stub.setResults([makeHit("A")], for: "weather prague")
        let cache = CachingWebSearchEngine(upstream: stub, ttl: 60, capacity: 10)

        _ = await cache.search(query: "weather prague")
        _ = await cache.search(query: "Weather Prague")
        _ = await cache.search(query: "  WEATHER PRAGUE  ")

        let count = await stub.callCount(for: "weather prague")
        XCTAssertEqual(count, 1, "Lower-case + trim must collapse to one cache key")
    }

    func testDifferentQueriesGoToUpstreamSeparately() async {
        let stub = StubEngine()
        await stub.setResults([makeHit("A")], for: "q1")
        await stub.setResults([makeHit("B")], for: "q2")
        let cache = CachingWebSearchEngine(upstream: stub, ttl: 60, capacity: 10)

        let r1 = await cache.search(query: "q1")
        let r2 = await cache.search(query: "q2")

        XCTAssertEqual(r1.first?.title, "A")
        XCTAssertEqual(r2.first?.title, "B")
        let c1 = await stub.callCount(for: "q1")
        let c2 = await stub.callCount(for: "q2")
        XCTAssertEqual(c1, 1)
        XCTAssertEqual(c2, 1)
    }

    func testEmptyQueryReturnsEmptyWithoutHittingUpstream() async {
        let stub = StubEngine()
        let cache = CachingWebSearchEngine(upstream: stub, ttl: 60, capacity: 10)

        let results = await cache.search(query: "   ")

        XCTAssertEqual(results.count, 0)
        let count = await stub.callCount(for: "")
        XCTAssertEqual(count, 0, "Whitespace-only query must short-circuit")
    }

    // MARK: - TTL expiry

    func testExpiredEntryRefetches() async {
        let stub = StubEngine()
        await stub.setResults([makeHit("A")], for: "expiring")
        // 0.1 s TTL — fast enough to test without flakiness budget.
        let cache = CachingWebSearchEngine(upstream: stub, ttl: 0.1, capacity: 10)

        _ = await cache.search(query: "expiring")
        try? await Task.sleep(nanoseconds: 200_000_000)   // 0.2 s
        _ = await cache.search(query: "expiring")

        let count = await stub.callCount(for: "expiring")
        XCTAssertEqual(count, 2, "Expired entry must trigger a refetch")
    }

    // MARK: - Empty result not cached

    func testEmptyResultsNotCached() async {
        let stub = StubEngine()
        // No canned results → stub returns [] for "missing".
        let cache = CachingWebSearchEngine(upstream: stub, ttl: 60, capacity: 10)

        _ = await cache.search(query: "missing")
        _ = await cache.search(query: "missing")

        let count = await stub.callCount(for: "missing")
        XCTAssertEqual(count, 2, "Empty result must NOT be cached — outages would otherwise pin failure for 15 min")
    }

    // MARK: - LRU eviction

    func testEvictsOldestWhenOverCapacity() async {
        let stub = StubEngine()
        for i in 0..<5 {
            await stub.setResults([makeHit("R\(i)")], for: "q\(i)")
        }
        let cache = CachingWebSearchEngine(upstream: stub, ttl: 60, capacity: 3)

        // Fill cache with q0, q1, q2 (in that order — newest last).
        for i in 0..<3 {
            _ = await cache.search(query: "q\(i)")
        }
        // Overflow with q3, q4. q0 + q1 should be evicted; q2/q3/q4 retained.
        _ = await cache.search(query: "q3")
        _ = await cache.search(query: "q4")

        // Verify q2 is still cached → must NOT refetch (call count stays 1).
        // We probe q2 BEFORE q0 deliberately: re-querying q0 is a miss that
        // re-inserts q0 into a full cache, which evicts the LRU entry —
        // which at that moment is q2. Probing q2 first records the
        // "retained?" assertion against the post-overflow cache state
        // without contaminating it with the q0 re-insertion side effect.
        _ = await cache.search(query: "q2")
        // Re-query q0 → must refetch (1 → 2 calls).
        _ = await cache.search(query: "q0")

        let c0 = await stub.callCount(for: "q0")
        let c2 = await stub.callCount(for: "q2")
        XCTAssertEqual(c0, 2, "Evicted entry must refetch")
        XCTAssertEqual(c2, 1, "Retained entry must NOT refetch")
    }

    func testHitPromotesEntryToMostRecentlyUsed() async {
        let stub = StubEngine()
        for i in 0..<5 {
            await stub.setResults([makeHit("R\(i)")], for: "q\(i)")
        }
        let cache = CachingWebSearchEngine(upstream: stub, ttl: 60, capacity: 3)

        // Fill: q0, q1, q2.
        for i in 0..<3 {
            _ = await cache.search(query: "q\(i)")
        }
        // Touch q0 — should jump to most-recently-used. Order now: q1, q2, q0.
        _ = await cache.search(query: "q0")
        // Overflow with q3. Oldest is now q1, not q0.
        _ = await cache.search(query: "q3")

        // q0 should still be cached; q1 should have been evicted.
        _ = await cache.search(query: "q0")
        _ = await cache.search(query: "q1")

        let c0 = await stub.callCount(for: "q0")
        let c1 = await stub.callCount(for: "q1")
        XCTAssertEqual(c0, 1, "Promoted entry must still be cached")
        XCTAssertEqual(c1, 2, "Demoted entry must refetch")
    }

    // MARK: - clear()

    func testClearForcesNextRefetch() async {
        let stub = StubEngine()
        await stub.setResults([makeHit("A")], for: "q")
        let cache = CachingWebSearchEngine(upstream: stub, ttl: 60, capacity: 10)

        _ = await cache.search(query: "q")
        await cache.clear()
        _ = await cache.search(query: "q")

        let count = await stub.callCount(for: "q")
        XCTAssertEqual(count, 2, "clear() must invalidate every cached entry")
    }

    // MARK: - diagnostics()

    func testDiagnosticsReportsEntryCount() async {
        let stub = StubEngine()
        for i in 0..<3 {
            await stub.setResults([makeHit("R\(i)")], for: "q\(i)")
            _ = i  // silence
        }
        let cache = CachingWebSearchEngine(upstream: stub, ttl: 60, capacity: 10)

        for i in 0..<3 {
            _ = await cache.search(query: "q\(i)")
        }

        let diag = await cache.diagnostics()
        XCTAssertEqual(diag.entries, 3)
    }
}

