import XCTest
@testable import HomeHub

/// `DiagnosticReport` is the structured payload behind the "Copy
/// diagnostics JSON" button in Developer Diagnostics. Tests pin down:
///
/// 1. The report serialises cleanly to JSON the user can paste into
///    a bug report.
/// 2. Every field the diagnostics screen renders has a matching key in
///    the JSON — that's the whole reason the report exists, so a
///    regression here defeats the feature.
/// 3. Sensitive fields (conversation contents, memory facts, user
///    profile) NEVER appear in the report.
final class DiagnosticReportTests: XCTestCase {

    // MARK: - Fixture

    private func sampleReport() -> DiagnosticReport {
        DiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.0.0",
            device: .init(
                modelName: "iPhone",
                systemVersion: "17.5",
                isPhone: true,
                isSimulator: false
            ),
            build: .init(
                cppBridge: "llama.cpp",
                downloadMode: "URLSession background (real)",
                realRuntimeFlag: true
            ),
            runtime: .init(
                identifier: "llama.cpp",
                state: "ready: gemma-2-2b-it-Q4_K_M",
                failureReason: nil
            ),
            activeModel: .init(
                id: "gemma-2-2b-it-q4_k_m",
                displayName: "Gemma 2 2B Instruct",
                family: "Gemma2",
                parameterCount: "2B",
                quantization: "Q4_K_M",
                sizeBytes: 1_500_000_000,
                contextLength: 4096
            ),
            lastGeneration: .init(
                ttftMs: 1_240,
                tokensPerSecond: 9.4,
                totalDurationMs: 5_300
            ),
            memory: .init(
                memoryWarningCount: 1,
                lastUnloadNotification: "12:34:56 – 'Gemma 2 2B' unloaded (memory pressure #1)"
            ),
            settings: .init(
                temperature: 0.7,
                topP: 0.9,
                topK: 40,
                minP: 0.05,
                repeatPenalty: 1.1,
                repeatPenaltyLastN: 64,
                maxResponseTokens: 768,
                answerLength: "balanced",
                language: "auto"
            ),
            catalog: .init(
                total: 5,
                installed: 1,
                downloading: 0,
                failed: 0,
                userAdded: 0
            ),
            lastBudget: .init(
                family: "Gemma2",
                mode: "chat",
                totalPromptTokens: 432,
                historyKept: 4,
                historyDropped: 0
            ),
            recentTelemetry: [
                "12:30:01 ✓ Loaded 'Gemma 2 2B' 1840ms",
                "12:30:05 ▶ Generation started",
                "12:30:06 ⚡ First token 1240ms",
                "12:30:11 ■ 50t @ 9.4t/s (5300ms)"
            ]
        )
    }

    // MARK: - JSON encoding

    func testJSONStringIsValidJSON() throws {
        let json = sampleReport().jsonString()
        let data = try XCTUnwrap(json.data(using: .utf8))
        // Round-trip via JSONSerialization to assert syntactic validity
        // without binding to any particular Decodable.
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        XCTAssertNotNil(parsed as? [String: Any])
    }

    func testRoundTripsThroughCodable() throws {
        let original = sampleReport()
        let json = original.jsonString()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticReport.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testJSONIsPrettyPrintedAndSorted() {
        let json = sampleReport().jsonString()
        // Pretty-printed JSON spans multiple lines; sortedKeys puts
        // `activeModel` before `appVersion` alphabetically — both
        // signal the encoder options are in effect (which matters for
        // diff-friendliness when users paste reports).
        XCTAssertTrue(json.contains("\n"), "Report should be pretty-printed.")
        let activeIdx = json.range(of: "\"activeModel\"")?.lowerBound
        let versionIdx = json.range(of: "\"appVersion\"")?.lowerBound
        XCTAssertNotNil(activeIdx)
        XCTAssertNotNil(versionIdx)
        XCTAssertTrue(activeIdx! < versionIdx!,
            "Sorted keys should put activeModel before appVersion.")
    }

    // MARK: - Field presence

    func testKeyDiagnosticsFieldsArePresent() {
        let json = sampleReport().jsonString()
        // These are the exact fields the diagnostics UI shows. A
        // regression that drops any of them silently degrades the
        // report's usefulness in a bug thread.
        let mustContain = [
            "\"appVersion\"",
            "\"device\"",
            "\"runtime\"",
            "\"state\"",
            "\"activeModel\"",
            "\"lastGeneration\"",
            "\"ttftMs\"",
            "\"tokensPerSecond\"",
            "\"settings\"",
            "\"temperature\"",
            "\"topP\"",
            "\"topK\"",
            "\"minP\"",
            "\"repeatPenalty\"",
            "\"memory\"",
            "\"memoryWarningCount\"",
            "\"catalog\"",
            "\"lastBudget\"",
            "\"recentTelemetry\""
        ]
        for key in mustContain {
            XCTAssertTrue(json.contains(key), "Diagnostic JSON missing key \(key)")
        }
    }

    // MARK: - Privacy guards

    func testReportNeverEncodesUnexpectedKeys() throws {
        // Belt-and-braces guard against future contributors adding a
        // "conversation" / "messages" / "facts" / "userProfile" field
        // to DiagnosticReport without remembering this is shareable.
        let data = try XCTUnwrap(sampleReport().jsonString().data(using: .utf8))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowedKeys: Set<String> = [
            "generatedAt", "appVersion", "device", "build", "runtime",
            "activeModel", "lastGeneration", "memory", "settings",
            "catalog", "lastBudget", "recentTelemetry"
        ]
        let actualKeys = Set(dict.keys)
        let extras = actualKeys.subtracting(allowedKeys)
        XCTAssertTrue(extras.isEmpty,
            "Diagnostic report has unexpected top-level key(s): \(extras). " +
            "Anything new shipped here goes to user bug reports — confirm " +
            "it's not personal data before adding to the allow-list.")
    }

    func testReportEncodesNilActiveModelGracefully() throws {
        var report = sampleReport()
        let nilActive = DiagnosticReport(
            generatedAt: report.generatedAt,
            appVersion: report.appVersion,
            device: report.device,
            build: report.build,
            runtime: .init(identifier: "mock", state: "idle", failureReason: nil),
            activeModel: nil,
            lastGeneration: .init(ttftMs: nil, tokensPerSecond: nil, totalDurationMs: nil),
            memory: report.memory,
            settings: report.settings,
            catalog: report.catalog,
            lastBudget: nil,
            recentTelemetry: []
        )
        report = nilActive
        let json = report.jsonString()
        // Nil optionals serialise as `null` (Swift JSONEncoder default).
        // The important thing is that the encoder doesn't crash and the
        // resulting JSON is still valid.
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
}
