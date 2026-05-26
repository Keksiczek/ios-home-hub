import XCTest
@testable import HomeHub

/// Coverage for `DocumentReaderService.extractPagesWithOCRFallback`.
///
/// The OCR fast-path lives behind Apple's Vision framework, which is
/// expensive to invoke in a unit test (loads ML models on first use)
/// and effectively impossible to feed deterministic input to without
/// shipping a binary PDF fixture. These tests focus on the parts of
/// the new pipeline that are pure-logic:
///
///   * Plain-text formats fall through the OCR fallback path
///     unchanged — no Vision invocation, no async cost.
///   * The empty-file case surfaces `extractionFailed`, not the
///     misleading `ocrYieldedNothing` (OCR was never attempted).
///   * Unknown formats keep producing `unknownFormat` so the user
///     gets the original "not supported" message.
///
/// The actual PDF render → Vision OCR pathway is covered by manual
/// QA on a sample scanned PDF; adding a binary fixture here would
/// bloat the test bundle by several MB for marginal automated value.
final class DocumentReaderOCRFallbackTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentReaderOCRFallbackTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Plain text passes through unchanged

    func testTXTFileShortCircuitsWithoutOCR() async throws {
        let url = tempDir.appendingPathComponent("notes.txt")
        try "Hello world. This is a plain text file.".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )

        let pages = try await DocumentReaderService.extractPagesWithOCRFallback(from: url)
        XCTAssertEqual(pages.count, 1)
        XCTAssertNil(pages.first?.pageNumber, "txt has no page numbers")
        XCTAssertTrue(pages.first?.text.contains("Hello world") ?? false)
    }

    func testMarkdownFileShortCircuitsWithoutOCR() async throws {
        let url = tempDir.appendingPathComponent("notes.md")
        try "# Heading\n\nBody text.".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )

        let pages = try await DocumentReaderService.extractPagesWithOCRFallback(from: url)
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages.first?.text.contains("# Heading") ?? false)
    }

    // MARK: - Empty text file: extractionFailed, not ocrYieldedNothing

    func testEmptyTXTFails_extractionFailed_notOCRPath() async {
        let url = tempDir.appendingPathComponent("empty.txt")
        try? "".write(to: url, atomically: true, encoding: .utf8)

        do {
            _ = try await DocumentReaderService.extractPagesWithOCRFallback(from: url)
            XCTFail("expected extractionFailed for empty txt")
        } catch DocumentReaderService.DocumentError.extractionFailed {
            // Correct: OCR is PDF-only; empty txt surfaces the
            // original extractionFailed, not the misleading
            // ocrYieldedNothing.
        } catch {
            XCTFail("expected extractionFailed, got \(error)")
        }
    }

    // MARK: - Unknown formats still rejected

    func testUnknownExtensionThrowsUnknownFormat() async {
        let url = tempDir.appendingPathComponent("data.xyz")
        try? "some bytes".write(to: url, atomically: true, encoding: .utf8)

        do {
            _ = try await DocumentReaderService.extractPagesWithOCRFallback(from: url)
            XCTFail("expected unknownFormat")
        } catch DocumentReaderService.DocumentError.unknownFormat(let ext) {
            XCTAssertEqual(ext, "xyz")
        } catch {
            XCTFail("expected unknownFormat, got \(error)")
        }
    }

    // MARK: - Error messages stay user-friendly

    func testOCRYieldedNothingHasActionableMessage() {
        let msg = DocumentReaderService.DocumentError.ocrYieldedNothing.errorDescription ?? ""
        XCTAssertTrue(msg.contains("OCR"), "user-facing message should mention OCR so the cause is obvious")
        XCTAssertFalse(msg.contains("nepodporujeme OCR"), "old 'OCR not supported' wording must not regress")
    }

    func testExtractionFailedMessageNoLongerClaimsOCRMissing() {
        let msg = DocumentReaderService.DocumentError.extractionFailed.errorDescription ?? ""
        // Pre-OCR-fallback the message said "zatím nepodporujeme OCR".
        // After the fallback exists we keep the message generic so it
        // doesn't lie about a capability we now have.
        XCTAssertFalse(
            msg.contains("nepodporujeme OCR"),
            "extractionFailed must not claim OCR is unsupported now that the fallback exists"
        )
    }
}
