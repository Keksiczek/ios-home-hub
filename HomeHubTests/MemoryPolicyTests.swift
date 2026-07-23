import XCTest
@testable import HomeHub

/// Unit tests for the memory-policy primitives that aren't already
/// covered by `RuntimeManagerLifecycleTests` (which exercises the
/// lifecycle handlers) or the integration suite:
///
/// 1. **Feasibility oracle** — pure function over `(model, profile,
///    available)`. The integration paths consume it but never assert
///    its outputs directly; this file pins each of the three verdicts
///    against synthetic memory snapshots.
/// 2. **Headroom display** — verifies that the `currentHeadroom(...)`
///    function used by the `ModelsView` strip compares against the
///    *raw* reference (no profile-derived safety factor). Regression
///    test for the bug where the strip lit up "low" on every iPhone
///    because `2 GB × 1.5 = 3 GB` exceeded the per-process available
///    limit.
///
/// All tests pass an explicit `available:` value so they don't depend
/// on the sysctl at test time.
final class MemoryPolicyTests: XCTestCase {

    // MARK: - Fixtures

    /// Mid-size 4-bit model (~Llama-3.2-3B class). Used as the "this is
    /// the user's everyday model" anchor for the feasibility tests.
    private static let referenceModel = LocalModel(
        id: "test-3b-4bit",
        displayName: "Test 3B",
        family: "llama",
        parameterCount: "3B",
        quantization: "4-bit",
        sizeBytes: 2_000_000_000,        // 2 GB on the dot
        contextLength: 2048,
        downloadURL: URL(string: "https://example.com/model")!,
        sha256: nil,
        installState: .notInstalled,
        recommendedFor: [.iPhone],
        license: "MIT"
    )

    // MARK: - Feasibility oracle

    /// Safe verdict requires `available >= sizeBytes × safetyFactor`.
    /// For the balanced profile (1.5) on the 2 GB reference, that's
    /// 3 GB. 3.5 GB beats the threshold and reports headroom of 0.5 GB.
    func testFeasibilitySafeWhenAvailableExceedsSafeMargin() {
        let verdict = RuntimeManager.evaluateFeasibility(
            for: Self.referenceModel,
            profile: .balanced,
            available: 3_500_000_000
        )
        guard case .safe(let headroom) = verdict else {
            return XCTFail("Expected .safe, got \(String(describing: verdict))")
        }
        XCTAssertEqual(headroom, 500_000_000, accuracy: 1_000)
    }

    /// Risky verdict fires when `available` covers the raw weights but
    /// not the safety margin. 2.5 GB ≥ 2 GB raw but < 3 GB safe → risky.
    /// The verdict's `permitsLoad` must still return `true`: risky loads
    /// proceed under user opt-in (the integration code in
    /// `_performLoad` logs and continues).
    func testFeasibilityRiskyWhenAvailableCoversRawButNotMargin() {
        let verdict = RuntimeManager.evaluateFeasibility(
            for: Self.referenceModel,
            profile: .balanced,
            available: 2_500_000_000
        )
        guard case .risky(let required, let avail) = verdict else {
            return XCTFail("Expected .risky, got \(String(describing: verdict))")
        }
        XCTAssertEqual(required, 3_000_000_000)
        XCTAssertEqual(avail, 2_500_000_000)
        XCTAssertTrue(verdict?.permitsLoad == true,
                      ".risky must permit load — user opt-in semantics")
    }

    /// CannotLoad vetoes when even the raw weights don't fit.
    /// 1.5 GB < 2 GB raw → no chance. `permitsLoad == false` is the
    /// only veto path the load gate honours.
    /// `.cannotLoad` fires only below the mmap floor (raw × 0.66), not merely
    /// below raw weights.
    ///
    /// This test used to pass `available: 1.5 GB` and expect `.cannotLoad`,
    /// encoding the old `weights × 1.35 > available` gate. That gate was
    /// deliberately removed (documented in `MLXRuntime`): MLX memory-maps weight
    /// files, so clean file-backed pages don't count fully against the dirty
    /// budget, and a model whose raw size modestly exceeds the budget still
    /// loads. For the 2 GB reference the floor is 1.32 GB, so 1.5 GB is
    /// correctly `.risky` (allowed under the user's explicit opt-in), not a
    /// hard refusal. The test now checks the real boundary: below the floor.
    func testFeasibilityCannotLoadBelowMmapFloor() {
        // 2 GB × 0.66 = 1.32 GB floor. 1.0 GB is below it — genuinely hopeless.
        let verdict = RuntimeManager.evaluateFeasibility(
            for: Self.referenceModel,
            profile: .balanced,
            available: 1_000_000_000
        )
        guard case .cannotLoad(let required, let avail) = verdict else {
            return XCTFail("Expected .cannotLoad below the mmap floor, got \(String(describing: verdict))")
        }
        XCTAssertEqual(required, 2_000_000_000, "cannotLoad reports raw weights as required")
        XCTAssertEqual(avail, 1_000_000_000)
        XCTAssertFalse(verdict?.permitsLoad == true,
                       ".cannotLoad must veto — this is the only block path")
    }

    /// The band between the mmap floor and the safe margin is `.risky`, not a
    /// refusal — the case the old test got wrong. 1.5 GB sits above the 1.32 GB
    /// floor and below the 3 GB safe margin for the 2 GB reference.
    func testFeasibilityRiskyBetweenFloorAndSafeMargin() {
        let verdict = RuntimeManager.evaluateFeasibility(
            for: Self.referenceModel,
            profile: .balanced,
            available: 1_500_000_000
        )
        guard case .risky(let required, let avail) = verdict else {
            return XCTFail("Expected .risky between floor and safe margin, got \(String(describing: verdict))")
        }
        XCTAssertEqual(required, 3_000_000_000, "risky reports the safe margin (raw × 1.5) as required")
        XCTAssertEqual(avail, 1_500_000_000)
        XCTAssertTrue(verdict?.permitsLoad == true,
                      ".risky permits load under the user's explicit opt-in")
    }

    /// The conservative profile (factor 1.8) raises the safe-margin
    /// threshold from 3 GB to 3.6 GB for the same model. An available
    /// value that was `.safe` on balanced should become `.risky` on
    /// conservative. Locks down the profile-respects-factor contract
    /// since a typo (e.g. flipping balanced and conservative) would
    /// silently change user-visible behaviour.
    func testFeasibilityProfileFactorAppliedCorrectly() {
        let balanced = RuntimeManager.evaluateFeasibility(
            for: Self.referenceModel,
            profile: .balanced,
            available: 3_400_000_000
        )
        let conservative = RuntimeManager.evaluateFeasibility(
            for: Self.referenceModel,
            profile: .conservative,
            available: 3_400_000_000
        )
        if case .safe = balanced { /* expected */ } else {
            XCTFail("Balanced @3.4 GB should be .safe, got \(String(describing: balanced))")
        }
        if case .risky = conservative { /* expected */ } else {
            XCTFail("Conservative @3.4 GB should be .risky, got \(String(describing: conservative))")
        }
    }

    /// Zero-sized models (user-added entries without a manifest probe
    /// yet) can't be evaluated — the oracle returns `nil` so the load
    /// gate skips the check entirely rather than rejecting outright.
    func testFeasibilityNilForUnsizedModel() {
        var unsized = Self.referenceModel
        unsized = LocalModel(
            id: unsized.id,
            displayName: unsized.displayName,
            family: unsized.family,
            parameterCount: unsized.parameterCount,
            quantization: unsized.quantization,
            sizeBytes: 0,
            contextLength: unsized.contextLength,
            downloadURL: unsized.downloadURL,
            sha256: unsized.sha256,
            installState: unsized.installState,
            recommendedFor: unsized.recommendedFor,
            license: unsized.license
        )
        let verdict = RuntimeManager.evaluateFeasibility(
            for: unsized,
            profile: .balanced,
            available: 4_000_000_000
        )
        XCTAssertNil(verdict, "Zero-byte model must short-circuit to nil")
    }

    // MARK: - Headroom display

    /// Regression guard for the strip-shows-low-on-every-iPhone bug.
    /// With 3.1 GB available — comfortably above the 2 GB reference,
    /// even close to the previous `2 GB × 1.5 = 3 GB` threshold — the
    /// display must report `.high` (≥ ref × 1.5), not `.low`. The fix
    /// dropped the factor from the display path; this test pins that.
    func testHeadroomDisplayDoesNotApplySafetyFactor() {
        let headroom = RuntimeManager.currentHeadroom(
            profile: .balanced,
            available: 3_100_000_000
        )
        XCTAssertEqual(headroom, .high,
                       "3.1 GB ≥ ref (2 GB) × 1.5 → .high; if .medium or .low " +
                       "the safety factor leaked back into the display path.")
    }

    /// Medium bucket: available in [ref, ref × 1.5).
    func testHeadroomMediumBucket() {
        let headroom = RuntimeManager.currentHeadroom(
            profile: .balanced,
            available: 2_500_000_000
        )
        XCTAssertEqual(headroom, .medium)
    }

    /// Low bucket: available below the bare reference.
    func testHeadroomLowBucket() {
        let headroom = RuntimeManager.currentHeadroom(
            profile: .balanced,
            available: 1_500_000_000
        )
        XCTAssertEqual(headroom, .low)
    }

    /// Profile no longer influences the display verdict — same
    /// available value should bucket identically across all three
    /// profiles. This is the contract that lets the strip stay stable
    /// when the user toggles the performance profile in Settings.
    func testHeadroomDisplayIgnoresProfile() {
        let available: Int64 = 2_500_000_000
        let aggressive   = RuntimeManager.currentHeadroom(profile: .aggressive,   available: available)
        let balanced     = RuntimeManager.currentHeadroom(profile: .balanced,     available: available)
        let conservative = RuntimeManager.currentHeadroom(profile: .conservative, available: available)
        XCTAssertEqual(aggressive, balanced)
        XCTAssertEqual(balanced, conservative)
    }
}
