import XCTest
@testable import HomeHub

/// Storage-layer coverage for `OOMTelemetryService`.
///
/// The production singleton (`OOMTelemetryService.shared`) subscribes to
/// MetricKit and writes into `Documents/oom-breadcrumbs.json` — neither
/// of which is friendly to unit tests. These tests instead drive the
/// service through the dedicated test seam initialiser
/// (`init(logURL:maxEntries:)`), which binds the JSON store to a
/// per-test temp file and lets us shrink `maxEntries` so eviction can be
/// exercised in a few writes instead of 201.
///
/// Each test uses a freshly minted temp URL so cases are fully
/// isolated; the file is removed in `tearDown` to keep the simulator
/// scratch directory tidy.
@MainActor
final class OOMTelemetryServiceTests: XCTestCase {

    private var logURL: URL!

    override func setUp() {
        super.setUp()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OOMTelemetryServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("oom-breadcrumbs.json")
    }

    override func tearDown() {
        if let parent = logURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }
        logURL = nil
        super.tearDown()
    }

    // MARK: - Storage round-trip

    /// `breadcrumb(...)` must persist a record that survives a process-
    /// boundary read (we simulate this by constructing a second service
    /// pointed at the same URL). Pin the kind, message, and context so
    /// regressions in `append` / `write` / `readAll` get caught.
    func testBreadcrumbPersistsAndReloads() {
        let service = OOMTelemetryService(logURL: logURL)
        service.breadcrumb("test.load", message: "weights mapped", context: ["modelID": "gemma3n-e2b"])

        let reloaded = OOMTelemetryService(logURL: logURL)
        let entries = reloaded.recentBreadcrumbs(limit: 50)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, "test.load")
        XCTAssertEqual(entries.first?.message, "weights mapped")
        XCTAssertEqual(entries.first?.context["modelID"], "gemma3n-e2b")
        // `availableMemoryMB` is sampled from the live process; we
        // can't pin a value but it must be non-negative.
        XCTAssertGreaterThanOrEqual(entries.first?.availableMemoryMB ?? -1, 0)
    }

    /// `recentBreadcrumbs(limit:)` returns newest-first and clips to
    /// the requested limit. The order matters — the DeveloperDiagnostics
    /// view relies on this contract to render the freshest landmark at
    /// the top without further sorting.
    func testRecentBreadcrumbsAreNewestFirstAndLimited() {
        let service = OOMTelemetryService(logURL: logURL)
        service.breadcrumb("a")
        service.breadcrumb("b")
        service.breadcrumb("c")
        service.breadcrumb("d")

        let limited = service.recentBreadcrumbs(limit: 2)
        XCTAssertEqual(limited.map(\.kind), ["d", "c"])

        let all = service.recentBreadcrumbs(limit: 50)
        XCTAssertEqual(all.map(\.kind), ["d", "c", "b", "a"])
    }

    // MARK: - Eviction

    /// When the on-disk count would exceed `maxEntries`, the oldest
    /// records get dropped from the front so the freshest N survive.
    /// A jetsam post-mortem cares about what happened *just before* the
    /// kill, so the eviction direction is load-bearing.
    func testEvictionDropsOldestBeyondMaxEntries() {
        let service = OOMTelemetryService(logURL: logURL, maxEntries: 3)
        service.breadcrumb("k1")
        service.breadcrumb("k2")
        service.breadcrumb("k3")
        service.breadcrumb("k4")
        service.breadcrumb("k5")

        let entries = service.recentBreadcrumbs(limit: 50)
        XCTAssertEqual(entries.count, 3)
        // Newest first → k5 leads, k1/k2 must be gone.
        XCTAssertEqual(entries.map(\.kind), ["k5", "k4", "k3"])
    }

    // MARK: - clear()

    /// `clear()` empties the file but leaves it parseable — a follow-up
    /// `recentBreadcrumbs` call returns `[]`, not stale data, and the
    /// next write must succeed.
    func testClearEmptiesTheLogAndAllowsFreshWrites() {
        let service = OOMTelemetryService(logURL: logURL)
        service.breadcrumb("before.clear")
        XCTAssertEqual(service.recentBreadcrumbs(limit: 50).count, 1)

        service.clear()
        XCTAssertEqual(service.recentBreadcrumbs(limit: 50).count, 0)

        service.breadcrumb("after.clear")
        let entries = service.recentBreadcrumbs(limit: 50)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, "after.clear")
    }

    // MARK: - Missing file

    /// First-run state: the JSON file doesn't exist yet. `readAll`
    /// must degrade to an empty list rather than throwing, and the
    /// first `breadcrumb` call must create the file from scratch.
    func testReadFromMissingFileReturnsEmpty() {
        let service = OOMTelemetryService(logURL: logURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(service.recentBreadcrumbs(limit: 50).isEmpty)

        service.breadcrumb("bootstrap")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertEqual(service.recentBreadcrumbs(limit: 50).map(\.kind), ["bootstrap"])
    }

    // MARK: - Public file URL

    /// `breadcrumbsFileURL` is what the DeveloperDiagnostics share
    /// sheet attaches to a bug report — it must point at the same
    /// path the service writes to, not some derived sibling.
    func testBreadcrumbsFileURLMatchesInitURL() {
        let service = OOMTelemetryService(logURL: logURL)
        XCTAssertEqual(service.breadcrumbsFileURL, logURL)
    }

    // MARK: - JSON shape

    /// The written JSON must be a flat array of `Breadcrumb` objects
    /// with stable field names — ad-hoc grep / `jq` scripts that
    /// triage bug reports rely on this shape. If the encoder ever
    /// nests these or renames keys, the script tooling breaks
    /// silently. Decode through the public type to lock the contract.
    func testWrittenFileDecodesAsBreadcrumbArray() throws {
        let service = OOMTelemetryService(logURL: logURL)
        service.breadcrumb("shape.check", message: "hello", context: ["k": "v"])

        let data = try Data(contentsOf: logURL)
        let decoded = try JSONDecoder().decode([OOMTelemetryService.Breadcrumb].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.kind, "shape.check")
        XCTAssertEqual(decoded.first?.message, "hello")
        XCTAssertEqual(decoded.first?.context["k"], "v")
        XCTAssertFalse(decoded.first?.timestamp.isEmpty ?? true)
    }
}
