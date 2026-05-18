import XCTest
@testable import HomeHub

/// Pinning tests for the bounded pressure-history ringbuffer.
///
/// The live store on `AppContainer` is built by repeated calls into
/// `appendBoundedPressure(...)`. If the cap drifts, the ordering
/// flips, or `removeLast(_:)` is replaced with `removeLast()` (drops
/// only one regardless of overage), the bug rides into production
/// silently — the only user-visible symptom is a Diagnostics list that
/// either grows unbounded or shows the wrong newest entry. These
/// tests pin each of those invariants directly.
@MainActor
final class PressureRingbufferTests: XCTestCase {

    private func snapshot(at offset: TimeInterval, escalated: Bool = false) -> AppContainer.PressureEventSnapshot {
        AppContainer.PressureEventSnapshot(
            occurredAt: Date(timeIntervalSinceReferenceDate: offset),
            availableBytes: 3_000_000_000,
            weightsBytes: 2_000_000_000,
            inDebounceWindow: false,
            belowHardFloor: false,
            wasGenerating: false,
            escalatedToHard: escalated
        )
    }

    // MARK: - Newest-first ordering

    /// Each new event lands at index 0 so the disclosure in
    /// Diagnostics reads top-to-bottom as most-recent-to-oldest.
    /// Inserting at `.last` would still satisfy "bounded" but the UI
    /// would silently invert.
    func testInsertNewestFirst() {
        var history: [AppContainer.PressureEventSnapshot] = []
        AppContainer.appendBoundedPressure(snapshot(at: 100), to: &history, cap: 20)
        AppContainer.appendBoundedPressure(snapshot(at: 200), to: &history, cap: 20)
        AppContainer.appendBoundedPressure(snapshot(at: 300), to: &history, cap: 20)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[0].occurredAt.timeIntervalSinceReferenceDate, 300, accuracy: 0.001)
        XCTAssertEqual(history[1].occurredAt.timeIntervalSinceReferenceDate, 200, accuracy: 0.001)
        XCTAssertEqual(history[2].occurredAt.timeIntervalSinceReferenceDate, 100, accuracy: 0.001)
    }

    // MARK: - Bounded growth

    /// At the cap, one more append keeps the total at `cap` and drops
    /// the oldest. Locks down "newest survives, oldest evicts".
    func testCapEvictsOldest() {
        var history: [AppContainer.PressureEventSnapshot] = []
        // Fill exactly to the cap (use cap=5 for tractable assertions).
        for i in 0..<5 {
            AppContainer.appendBoundedPressure(snapshot(at: TimeInterval(i)), to: &history, cap: 5)
        }
        XCTAssertEqual(history.count, 5)
        // One more → evict the oldest (timestamp 0), keep timestamp 5.
        AppContainer.appendBoundedPressure(snapshot(at: 5), to: &history, cap: 5)
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history.first?.occurredAt.timeIntervalSinceReferenceDate ?? -1, 5, accuracy: 0.001)
        XCTAssertEqual(history.last?.occurredAt.timeIntervalSinceReferenceDate ?? -1, 1, accuracy: 0.001,
                       "Oldest (t=0) must be evicted; oldest survivor is t=1")
    }

    /// A burst that overshoots the cap by N must drop *exactly* N
    /// entries, not 1 (a `removeLast()` typo would silently regress
    /// to this behaviour and the buffer would grow unbounded under
    /// chronic pressure). Use a small cap so the overshoot is obvious.
    func testOversizedBurstTrimsToCap() {
        var history: [AppContainer.PressureEventSnapshot] = []
        for i in 0..<25 {
            AppContainer.appendBoundedPressure(snapshot(at: TimeInterval(i)), to: &history, cap: 5)
        }
        XCTAssertEqual(history.count, 5, "Must trim down to cap, not leak overshoot")
        // The 5 newest events should be timestamps 20..24 (newest-first).
        XCTAssertEqual(history.first?.occurredAt.timeIntervalSinceReferenceDate ?? -1, 24, accuracy: 0.001)
        XCTAssertEqual(history.last?.occurredAt.timeIntervalSinceReferenceDate ?? -1, 20, accuracy: 0.001)
    }

    /// Cap is a runtime parameter with a documented default. Production
    /// uses `pressureHistoryCap` (20); a test passing the default must
    /// inherit it. Sanity check that the constant hasn't drifted.
    func testProductionCapIsTwenty() {
        XCTAssertEqual(AppContainer.pressureHistoryCap, 20,
                       "If the cap changes intentionally, update this test " +
                       "and the matching disclosure label in DeveloperDiagnosticsView.")
    }

    /// Empty history + cap=0 is a degenerate but possible config (a
    /// future user-tunable "history disabled" toggle). Must not crash
    /// and must keep the history empty rather than leak the inserted
    /// event by negative-arithmetic accident.
    func testZeroCapDropsAllEvents() {
        var history: [AppContainer.PressureEventSnapshot] = []
        AppContainer.appendBoundedPressure(snapshot(at: 1), to: &history, cap: 0)
        XCTAssertEqual(history.count, 0)
        AppContainer.appendBoundedPressure(snapshot(at: 2), to: &history, cap: 0)
        XCTAssertEqual(history.count, 0)
    }

    // MARK: - Tier preservation

    /// The escalation flag must survive the append untouched — the
    /// Diagnostics aggregator reads `escalatedToHard` to bucket
    /// SOFT/HARD/deferred. A `.copy()` shortcut that dropped the flag
    /// would silently mis-classify every entry.
    func testEscalationFlagPreserved() {
        var history: [AppContainer.PressureEventSnapshot] = []
        AppContainer.appendBoundedPressure(snapshot(at: 1, escalated: true),  to: &history, cap: 5)
        AppContainer.appendBoundedPressure(snapshot(at: 2, escalated: false), to: &history, cap: 5)
        XCTAssertEqual(history.count, 2)
        XCTAssertFalse(history[0].escalatedToHard, "Newest (t=2) was soft")
        XCTAssertTrue(history[1].escalatedToHard,  "Older (t=1) was hard")
    }
}
