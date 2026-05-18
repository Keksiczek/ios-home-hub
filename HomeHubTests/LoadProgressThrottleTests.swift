import XCTest
@testable import HomeHub

/// Behavioural tests for the loader-progress throttle.
///
/// The throttle's job is twofold:
///   1. **Coalesce** rapid same-phase ticks so the main actor doesn't
///      drown in `Task @MainActor` hops during a fast Wi-Fi download
///      (observed ~20-30 progress events/s).
///   2. **Always emit phase transitions** so the user sees the moment
///      a download flips into "preparing…" — a throttled transition
///      would leave the progress bar visibly stuck.
///
/// A regression in either direction is invisible without these tests:
/// dropping (1) returns the main-actor flood; dropping (2) leaves a
/// half-second UI lag at end of download. Both are silent in functional
/// QA because the model still loads correctly.
final class LoadProgressThrottleTests: XCTestCase {

    // MARK: - Phase transition: always emit

    /// The very first event after construction must emit — there is no
    /// prior state to compare against, and dropping it would mean the
    /// UI never receives the initial "preparing…" notification.
    func testFirstEventAlwaysEmits() {
        let throttle = LoadProgressThrottle(minIntervalMs: 100)
        XCTAssertTrue(throttle.shouldEmit(phase: .preparing))
    }

    /// `downloading` → `preparing` is the canonical phase transition
    /// at end of download. Must emit even when within the throttle
    /// window, or the UI keeps showing the download progress bar
    /// while the model is actually mid-Metal-compile.
    func testTransitionFromDownloadingToPreparingAlwaysEmits() {
        let throttle = LoadProgressThrottle(minIntervalMs: 100)
        _ = throttle.shouldEmit(phase: .downloading(fraction: 0.5))
        // Immediate transition — even though we're well inside the
        // 100 ms throttle window for downloading, the case change
        // bypasses the gate.
        XCTAssertTrue(throttle.shouldEmit(phase: .preparing))
    }

    /// Reverse transition (`preparing` → `downloading`) is rarer (the
    /// loader doesn't backtrack), but symmetric: a phase change is a
    /// phase change. Locks down the case-comparison logic.
    func testTransitionFromPreparingToDownloadingAlwaysEmits() {
        let throttle = LoadProgressThrottle(minIntervalMs: 100)
        _ = throttle.shouldEmit(phase: .preparing)
        XCTAssertTrue(throttle.shouldEmit(phase: .downloading(fraction: 0.1)))
    }

    // MARK: - Same-phase coalescing

    /// Two same-phase events within the throttle window: first emits
    /// (the transition into the phase), second drops. Varying the
    /// associated value (different fractions) must NOT defeat the
    /// throttle — that would re-introduce the flood.
    func testRapidDownloadingTicksAreCoalesced() {
        let throttle = LoadProgressThrottle(minIntervalMs: 100)
        // Seed the phase — the first downloading event is treated as
        // a transition (no prior phase) so it always emits.
        XCTAssertTrue(throttle.shouldEmit(phase: .downloading(fraction: 0.1)))
        // Within the window, with a DIFFERENT fraction: must still
        // coalesce. The throttle compares case, not value.
        XCTAssertFalse(throttle.shouldEmit(phase: .downloading(fraction: 0.2)))
        XCTAssertFalse(throttle.shouldEmit(phase: .downloading(fraction: 0.3)))
        XCTAssertFalse(throttle.shouldEmit(phase: .downloading(fraction: 0.4)))
    }

    /// After the throttle window elapses, the next same-phase event
    /// emits again. Uses a short interval (50 ms) so the test sleeps
    /// briefly rather than relying on a clock-injectable refactor.
    func testEmitsAgainAfterIntervalElapses() async {
        let throttle = LoadProgressThrottle(minIntervalMs: 50)
        XCTAssertTrue(throttle.shouldEmit(phase: .downloading(fraction: 0.1)))
        XCTAssertFalse(throttle.shouldEmit(phase: .downloading(fraction: 0.2)),
                       "Within 50 ms — must coalesce")

        // Sleep just past the window. We add slack (60 ms vs 50 ms
        // threshold) so a slightly slow CI scheduler doesn't false-
        // positive this test on the boundary.
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertTrue(throttle.shouldEmit(phase: .downloading(fraction: 0.3)),
                      "Past 50 ms — must emit again")
    }

    // MARK: - Throttle interval

    /// A zero-interval throttle should emit every event — same-phase
    /// or not. Useful as a "disable throttling" knob and as a sanity
    /// check that the interval comparison is `>=` rather than `>`.
    func testZeroIntervalEmitsEveryEvent() {
        let throttle = LoadProgressThrottle(minIntervalMs: 0)
        XCTAssertTrue(throttle.shouldEmit(phase: .downloading(fraction: 0.1)))
        XCTAssertTrue(throttle.shouldEmit(phase: .downloading(fraction: 0.2)))
        XCTAssertTrue(throttle.shouldEmit(phase: .downloading(fraction: 0.3)))
    }
}
