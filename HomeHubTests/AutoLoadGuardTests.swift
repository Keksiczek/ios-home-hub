import XCTest
@testable import HomeHub

/// Round-trip + migration tests for the crash-loop guard record.
///
/// The guard is the only thing standing between a model that crashes
/// the app at load time and a permanently broken install — if the
/// JSON encoding is wrong, the legacy migration silently drops the
/// model ID, or the stale-detection threshold flips, the user lands
/// in a soft-bricked state with no obvious recovery. The tests below
/// pin each of those invariants independently.
///
/// All tests use an isolated `UserDefaults(suiteName:)` so they don't
/// pollute or read from the production app group.
@MainActor
final class AutoLoadGuardTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "com.homehub.tests.autoLoadGuard"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        // Defensive: a prior run that crashed mid-test could leave
        // state behind. `removePersistentDomain` is idempotent and
        // cheap; it gives every test a known-empty starting point.
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - JSON round-trip

    /// Writing a record and reading it back must yield the same model
    /// ID and a timestamp within sub-millisecond of the original.
    /// `Date` is double-precision so we don't compare for equality.
    func testRoundTripPreservesFields() {
        let now = Date()
        let original = AppContainer.AutoLoadGuardRecord(
            modelID: "mlx-llama-3.2-3b-it",
            startedAt: now
        )
        AppContainer.writeAutoLoadGuardRecord(original, to: defaults)

        guard let decoded = AppContainer.readAutoLoadGuardRecord(from: defaults) else {
            return XCTFail("Failed to read record back")
        }
        XCTAssertEqual(decoded.modelID, original.modelID)
        XCTAssertEqual(decoded.startedAt.timeIntervalSince1970,
                       original.startedAt.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    /// Empty defaults → nil. This is the "first launch, no guard ever
    /// set" case; the autoload path treats nil as "go ahead and load".
    func testReadReturnsNilWhenEmpty() {
        XCTAssertNil(AppContainer.readAutoLoadGuardRecord(from: defaults))
    }

    /// JSON encoding under the well-known key — locks down the schema
    /// so a Codable refactor (adding a synthesised `Date` strategy,
    /// renaming a CodingKey) can't silently break in-place upgrades.
    func testWritePersistsJSONUnderExpectedKey() throws {
        let rec = AppContainer.AutoLoadGuardRecord(
            modelID: "mlx-test",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        AppContainer.writeAutoLoadGuardRecord(rec, to: defaults)

        // The value must be `Data` (JSON-encoded), not `String` —
        // string is the legacy shape that the migration branch reads.
        guard let data = defaults.data(forKey: AppContainer.autoLoadGuardKey) else {
            return XCTFail("Expected Data at autoLoadGuardKey")
        }
        let parsed = try JSONDecoder().decode(AppContainer.AutoLoadGuardRecord.self, from: data)
        XCTAssertEqual(parsed.modelID, "mlx-test")
    }

    // MARK: - Legacy migration

    /// Pre-v2 builds stored just the modelID as a String under the
    /// same key. The migration path must still return a record (so
    /// the guard fires) — but use `.now` as `startedAt` since the
    /// legacy format didn't carry one.
    func testLegacyStringFormatMigratesToRecord() {
        // Simulate a UserDefaults written by an old build: bare String
        // under the same key (no JSON wrapping).
        defaults.set("mlx-llama-legacy", forKey: AppContainer.autoLoadGuardKey)

        guard let rec = AppContainer.readAutoLoadGuardRecord(from: defaults) else {
            return XCTFail("Legacy migration should produce a record, not nil")
        }
        XCTAssertEqual(rec.modelID, "mlx-llama-legacy",
                       "Legacy modelID must survive migration")
        // startedAt is synthetic on migration — assert it's recent
        // (within 5 s) rather than equality.
        XCTAssertLessThan(abs(rec.startedAt.timeIntervalSinceNow), 5,
                          "Migrated startedAt should default to ~now")
    }

    /// Garbage JSON under the key must NOT crash and must NOT silently
    /// fall through to the legacy path (the bytes aren't a valid
    /// String either — `defaults.string(forKey:)` returns nil for
    /// Data values). The contract: corrupt data → nil → autoload
    /// proceeds normally rather than blocking on an unparseable record.
    func testCorruptDataReturnsNil() {
        defaults.set(Data([0xFF, 0x00, 0xDE, 0xAD]), forKey: AppContainer.autoLoadGuardKey)
        XCTAssertNil(AppContainer.readAutoLoadGuardRecord(from: defaults),
                     "Corrupt JSON must downgrade to nil, not throw or hang")
    }

    /// Overwriting an existing record must replace, not merge. A
    /// previous load of model A followed by a new load of model B
    /// must produce a record whose `modelID == "B"`.
    func testWriteOverwritesPreviousRecord() {
        AppContainer.writeAutoLoadGuardRecord(
            .init(modelID: "A", startedAt: Date(timeIntervalSinceNow: -100)),
            to: defaults
        )
        AppContainer.writeAutoLoadGuardRecord(
            .init(modelID: "B", startedAt: Date()),
            to: defaults
        )
        XCTAssertEqual(AppContainer.readAutoLoadGuardRecord(from: defaults)?.modelID, "B")
    }
}
