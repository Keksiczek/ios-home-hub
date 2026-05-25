import Foundation
import MetricKit
import os

/// MetricKit subscriber that persists jetsam / hang / crash diagnostics
/// to a local JSON log file, so a user reporting "the app died loading
/// Gemma 3n" can attach a concrete breadcrumb trail instead of "it just
/// crashed". MetricKit fires `didReceive` once every ~24 h with the
/// aggregated payloads since the last delivery, so this file accumulates
/// rather than replaces — older entries are evicted only when the file
/// hits the `maxEntries` ceiling.
///
/// The companion `breadcrumb(...)` API writes synchronous landmark
/// events directly to the file (and to the unified log via `os_log`),
/// giving the post-mortem path coverage MetricKit can't — by the time
/// `MXDiagnosticPayload.crashDiagnostics` reports a jetsam, the load
/// that caused it is long over. Landmark events written before /
/// during the load are the ones a tail of the breadcrumb file will
/// show right after a fresh launch.
///
/// **Privacy**: written to `Documents/oom-breadcrumbs.json`, never
/// leaves the device unless the user explicitly shares it from
/// Developer Diagnostics.
@MainActor
final class OOMTelemetryService: NSObject {

    /// Singleton — `MetricKit.MXMetricManager` only delivers payloads
    /// to subscribers retained for the lifetime of the process, so a
    /// stack-local instance disappears before the next delivery
    /// window. Kept as a `let` global so AppContainer wiring is a
    /// one-liner.
    static let shared = OOMTelemetryService()

    private let log = Logger(subsystem: "HomeHub", category: "OOMTelemetry")
    private let logURL: URL
    private let maxEntries: Int
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Single breadcrumb record. Keep this struct flat — the JSON is
    /// meant to be greppable by hand and parseable by ad-hoc scripts
    /// without a schema library.
    struct Breadcrumb: Codable {
        let timestamp: String
        let kind: String
        let message: String
        let availableMemoryMB: Int64
        let context: [String: String]
    }

    override private init() {
        self.logURL = Self.defaultLogURL()
        self.maxEntries = 200
        super.init()
    }

    /// Test seam — lets unit tests drive the storage layer against a
    /// temp file with a smaller cap so eviction can be exercised
    /// without writing 201 entries. Not used in production; the live
    /// app always goes through `shared`.
    ///
    /// Production wiring depends on `shared` being a hot singleton
    /// retained for the process lifetime (MetricKit only delivers
    /// payloads to retained subscribers). Instances constructed via
    /// this initialiser intentionally do NOT subscribe to MetricKit —
    /// they're storage-layer fixtures.
    init(logURL: URL, maxEntries: Int = 200) {
        self.logURL = logURL
        self.maxEntries = maxEntries
        super.init()
    }

    // MARK: - Public API

    /// Wire MetricKit + write a "session start" landmark. Idempotent;
    /// safe to call from `AppContainer.live()` on every cold launch.
    func start() {
        MXMetricManager.shared.add(self)
        breadcrumb("session.start", context: [
            "build": Self.appBuildString(),
            "device": Self.deviceModelString()
        ])
    }

    /// Record a landmark event. Designed for the MLX load / generate
    /// pipeline — call from `loadWithProgress` (pre-flight start,
    /// weights mapped, prewarm done) and `generate` (prefill start,
    /// first token). `context` is free-form key/value for whatever's
    /// useful at that point in the pipeline — model id, weight size,
    /// pressure tier, etc.
    func breadcrumb(_ kind: String, message: String = "", context: [String: String] = [:]) {
        let crumb = Breadcrumb(
            timestamp: isoFormatter.string(from: Date()),
            kind: kind,
            message: message,
            availableMemoryMB: Int64(os_proc_available_memory()) / 1_048_576,
            context: context
        )
        log.info("breadcrumb \(kind, privacy: .public) avail=\(crumb.availableMemoryMB, privacy: .public)MB \(message, privacy: .public)")
        append(crumb)
    }

    /// Returns the most recent breadcrumbs, newest first. Used by
    /// DeveloperDiagnostics to render the in-app log view.
    func recentBreadcrumbs(limit: Int = 50) -> [Breadcrumb] {
        let all = readAll()
        return Array(all.suffix(limit).reversed())
    }

    /// Replace the on-disk file with an empty list. Exposed for the
    /// "clear log" action in DeveloperDiagnostics.
    func clear() {
        write([])
    }

    /// URL of the breadcrumb JSON — surfaced so the share sheet in
    /// DeveloperDiagnostics can attach the raw file to a bug report.
    var breadcrumbsFileURL: URL { logURL }

    // MARK: - Storage

    private static func defaultLogURL() -> URL {
        let fm = FileManager.default
        let documents = (try? fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documents.appendingPathComponent("oom-breadcrumbs.json")
    }

    private func readAll() -> [Breadcrumb] {
        guard let data = try? Data(contentsOf: logURL, options: .mappedIfSafe) else { return [] }
        return (try? JSONDecoder().decode([Breadcrumb].self, from: data)) ?? []
    }

    private func write(_ entries: [Breadcrumb]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic write so a crash mid-flush can't corrupt the file —
        // worst case we lose the last few breadcrumbs but the file
        // stays parseable on next read.
        if let data = try? encoder.encode(entries) {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func append(_ crumb: Breadcrumb) {
        var entries = readAll()
        entries.append(crumb)
        // Cap so a long-running install doesn't grow the file
        // unbounded. Drop from the front (oldest) so the most
        // recent N landmarks always survive — those are the ones
        // useful for a post-jetsam inspection.
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        write(entries)
    }

    // MARK: - Diagnostic helpers

    private static func appBuildString() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private static func deviceModelString() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}

// MARK: - MXMetricManagerSubscriber

extension OOMTelemetryService: MXMetricManagerSubscriber {

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // MetricKit dispatches on a background queue — bounce back to
        // the main actor to read/write the breadcrumb file (which is
        // main-actor isolated). One Task per payload keeps the
        // per-payload memory footprint bounded if the OS ever
        // batches many.
        for payload in payloads {
            let json = String(
                data: payload.jsonRepresentation(),
                encoding: .utf8
            ) ?? "(unreadable)"
            let begin = payload.timeStampBegin
            let end = payload.timeStampEnd
            Task { @MainActor in
                self.breadcrumb("metrickit.metric", context: [
                    "begin": ISO8601DateFormatter().string(from: begin),
                    "end":   ISO8601DateFormatter().string(from: end),
                    "bytes": "\(json.utf8.count)"
                ])
                // Persist the full JSON alongside so the bug report
                // can include the raw upstream payload. Files are
                // intentionally non-rotating — MetricKit delivers
                // ~once per 24 h so disk impact is negligible.
                self.persistRawPayload(json: json, suffix: "metric", at: end)
            }
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Diagnostic payloads are where the OOM / hang / crash data
        // lives. Same dispatch pattern as the metric branch.
        for payload in payloads {
            let json = String(
                data: payload.jsonRepresentation(),
                encoding: .utf8
            ) ?? "(unreadable)"
            let begin = payload.timeStampBegin
            let end = payload.timeStampEnd
            // Pull short counts out of the payload before we lose the
            // typed reference — counts of each diagnostic kind go
            // into the breadcrumb so a glance at the log shows "1
            // crash in the last 24 h" without opening the raw JSON.
            // Jetsam events surface as `crashDiagnostics` entries
            // tagged with a memory-related signal on iOS 16+.
            let diskWrites  = payload.diskWriteExceptionDiagnostics?.count ?? 0
            let cpuExceptions = payload.cpuExceptionDiagnostics?.count ?? 0
            let hangs       = payload.hangDiagnostics?.count ?? 0
            let crashes     = payload.crashDiagnostics?.count ?? 0
            Task { @MainActor in
                self.breadcrumb("metrickit.diagnostic", context: [
                    "begin": ISO8601DateFormatter().string(from: begin),
                    "end":   ISO8601DateFormatter().string(from: end),
                    "diskWriteExceptions": "\(diskWrites)",
                    "cpuExceptions":       "\(cpuExceptions)",
                    "hangs":               "\(hangs)",
                    "crashes":             "\(crashes)"
                ])
                self.persistRawPayload(json: json, suffix: "diagnostic", at: end)
            }
        }
    }

    private func persistRawPayload(json: String, suffix: String, at date: Date) {
        let stamp = isoFormatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        let url = logURL
            .deletingLastPathComponent()
            .appendingPathComponent("metrickit-\(suffix)-\(stamp).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
    }
}
