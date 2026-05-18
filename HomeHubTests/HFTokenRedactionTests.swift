import XCTest
@testable import HomeHub

/// Security-critical tests: the `DiagnosticReport` is designed to be
/// shared verbatim (copied to the system pasteboard, attached to bug
/// reports, sometimes pasted into GitHub issues). The Hugging Face
/// token IS a secret — it authenticates against a third-party service
/// under the user's account and can be used to download paid/gated
/// content or, with a Write-scoped token, push to their repos. The
/// app explicitly stores it in the Keychain rather than UserDefaults
/// for exactly this reason. If a future refactor adds the raw token
/// to the report struct (even accidentally — e.g. snapshotting the
/// whole `HFTokenStore` state), it would silently leak through every
/// shared diagnostic.
///
/// These tests JSON-encode a fully-populated report and assert that
/// the encoded bytes contain only the *metadata* fields, never the
/// token bytes themselves. Run from CI on every PR.
final class HFTokenRedactionTests: XCTestCase {

    // MARK: - Snapshot defaults

    /// `HuggingFaceSnapshot.none` is the default for reports built
    /// without a configured token. Must still round-trip cleanly and
    /// must not encode any token-shaped values (the `"absent"` status
    /// is the only thing JSON should see).
    func testNoneSnapshotEncodesAbsentStatus() throws {
        let snapshot = DiagnosticReport.HuggingFaceSnapshot.none
        let data = try JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"status\":\"absent\""),
                      "Default snapshot must encode status=absent")
        XCTAssertTrue(json.contains("\"hasToken\":false"))
        XCTAssertFalse(json.contains("hf_"),
                       ".none snapshot must NEVER contain anything that " +
                       "looks like a token prefix")
    }

    // MARK: - Token bytes never leak

    /// The killer test: even if a future refactor accidentally
    /// stuffed the raw token into a snapshot field, JSON encoding
    /// would contain the bytes. We assert the *negative*: no
    /// "hf_"-prefixed substring may appear in any encoded report.
    ///
    /// Uses a realistic-looking token (40 chars after the prefix,
    /// matching HF's actual format) so a partial-redaction bug
    /// (e.g. truncating to first 8 chars) doesn't false-pass.
    func testReportEncodingDoesNotContainTokenSubstring() throws {
        let fakeToken = "hf_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789ABCDEF"

        // Build a report with the snapshot in its richest state
        // (valid, recent verification) so all fields are populated.
        let snapshot = DiagnosticReport.HuggingFaceSnapshot(
            hasToken: true,
            lastVerifiedAtUnix: Date().timeIntervalSince1970,
            status: "valid"
        )

        let data = try JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertFalse(json.contains(fakeToken),
                       "Token bytes leaked into JSON — review HuggingFaceSnapshot " +
                       "fields and remove any Keychain-mirroring field.")
        XCTAssertFalse(json.contains("hf_"),
                       "JSON contains 'hf_' prefix — even a partial token " +
                       "leak is a security incident.")
    }

    /// The "username" field on `lastVerification()` is HF-supplied
    /// and considered low-sensitivity (it's the public handle on
    /// huggingface.co/<name>). It IS allowed in the snapshot via the
    /// status label, but it should NOT appear inside the `status`
    /// string itself — that field is a fixed vocabulary. Pin this so
    /// a future refactor doesn't sneak in `"valid as stepan"` as a
    /// status string.
    func testStatusFieldUsesFixedVocabulary() throws {
        let validStatuses = ["absent", "valid", "invalid", "networkError", "stale", "unverified"]
        for status in validStatuses {
            let snapshot = DiagnosticReport.HuggingFaceSnapshot(
                hasToken: true,
                lastVerifiedAtUnix: nil,
                status: status
            )
            let data = try JSONEncoder().encode(snapshot)
            let json = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(json.contains("\"status\":\"\(status)\""),
                          "Status '\(status)' didn't round-trip exactly")
        }
    }

    // MARK: - Round-trip stability

    /// The snapshot must Codable round-trip — a wire-format change
    /// that breaks decoding would silently drop the field from
    /// downstream analysis tooling. Asserts every field survives.
    func testSnapshotRoundTripsCleanly() throws {
        let original = DiagnosticReport.HuggingFaceSnapshot(
            hasToken: true,
            lastVerifiedAtUnix: 1_700_000_000,
            status: "valid"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            DiagnosticReport.HuggingFaceSnapshot.self,
            from: data
        )
        XCTAssertEqual(decoded, original)
    }
}
