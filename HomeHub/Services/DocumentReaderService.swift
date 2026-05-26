import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

/// Service responsible for extracting text from local files (PDFs, TXT, MD, etc.)
enum DocumentReaderService {

    /// One page of extracted text. `pageNumber` is 1-indexed for
    /// human-friendly citations; `nil` when the source format
    /// doesn't have pages (plain text, markdown). The chunker
    /// stamps this onto every produced `ChunkRecord` so the chat
    /// UI can render "see page 4" without re-running the parser.
    struct PageText: Sendable {
        let pageNumber: Int?
        let text: String
    }

    enum DocumentError: Error, LocalizedError {
        case fileNotReadable
        case unknownFormat(String)
        case extractionFailed
        /// PDF without a text layer AND OCR also produced nothing.
        /// Distinguished from `extractionFailed` so the UI can
        /// suggest a different action (re-scan at higher quality,
        /// crop to text area) rather than a generic retry.
        case ocrYieldedNothing

        var errorDescription: String? {
            switch self {
            case .fileNotReadable:
                return "Soubor nelze přečíst nebo k němu není přístup."
            case .unknownFormat(let ext):
                let hint = ext.isEmpty ? "Soubor nemá příponu." : ".\(ext) není podporován."
                return "Tento formát souboru zatím není podporován. \(hint) Podporované formáty: PDF, TXT, MD, CSV, JSON."
            case .extractionFailed:
                return "Z dokumentu se nepodařilo extrahovat žádný text."
            case .ocrYieldedNothing:
                return "PDF nemá textovou vrstvu a ani OCR z naskenovaných stránek nic nepřečetlo. Zkus vyšší rozlišení skenu nebo ořezat na samotný text."
            }
        }
    }
    
    /// Extract text content from a given file URL.
    /// Accesses the file securely using `startAccessingSecurityScopedResource` if the file comes from an external picker.
    static func extractText(from url: URL) throws -> String {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer {
            if isSecured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let fileExtension = url.pathExtension.lowercased()
        
        switch fileExtension {
        case "txt", "md", "csv", "json":
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw DocumentError.fileNotReadable
            }
            
        case "pdf":
            guard let pdf = PDFDocument(url: url) else {
                throw DocumentError.fileNotReadable
            }
            
            var extractedText = ""
            for i in 0..<pdf.pageCount {
                if let page = pdf.page(at: i), let pageText = page.string {
                    extractedText += pageText + "\n"
                }
            }
            
            let final = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if final.isEmpty {
                throw DocumentError.extractionFailed
            }
            return final
            
        default:
            throw DocumentError.unknownFormat(fileExtension)
        }
    }
    
    /// Per-page text extraction. Streams pages without ever holding
    /// the entire document in memory as a single concatenated
    /// string — important for large PDFs (>50 MB) where the
    /// `extractText` flat-string output would spike RAM by an
    /// order of magnitude on weak iPhones.
    ///
    /// For non-paginated formats (`txt` / `md` / `csv` / `json`)
    /// this returns a single `PageText` with `pageNumber == nil`.
    /// PDFs return one entry per page in document order.
    ///
    /// Throws the same errors as `extractText`. Empty pages are
    /// dropped (PDF pages with images or zero glyphs); a doc that
    /// produces zero non-empty pages throws `extractionFailed`.
    static func extractPages(from url: URL) throws -> [PageText] {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer { if isSecured { url.stopAccessingSecurityScopedResource() } }

        let fileExtension = url.pathExtension.lowercased()
        switch fileExtension {
        case "txt", "md", "csv", "json":
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw DocumentError.fileNotReadable
            }
            guard !text.isEmpty else { throw DocumentError.extractionFailed }
            return [PageText(pageNumber: nil, text: text)]

        case "pdf":
            guard let pdf = PDFDocument(url: url) else {
                throw DocumentError.fileNotReadable
            }
            var pages: [PageText] = []
            pages.reserveCapacity(pdf.pageCount)
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i),
                      let raw = page.string else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                pages.append(PageText(pageNumber: i + 1, text: trimmed))
            }
            guard !pages.isEmpty else { throw DocumentError.extractionFailed }
            return pages

        default:
            throw DocumentError.unknownFormat(fileExtension)
        }
    }

    /// Like `extractPages(from:)` but falls back to per-page Apple
    /// Vision OCR when a PDF page has no text layer. Use this on
    /// any path that may receive scanned-only PDFs (user file
    /// imports in chat, KB ingest of an arbitrary uploaded PDF).
    ///
    /// Flow:
    ///   1. Run synchronous PDFKit text extraction (cheap).
    ///   2. If at least one page produced text, return what we got.
    ///      Mixed PDFs (text + scan) are common — we don't OCR
    ///      pages that already have a text layer.
    ///   3. If every page came back empty, render each page to a
    ///      CGImage at ~144 DPI and feed it to `ImageVisionService`.
    ///   4. Throws `ocrYieldedNothing` if OCR also produced no
    ///      text on any page (image-only PDF, blank scans).
    ///
    /// Non-PDF formats short-circuit to the sync path — there's
    /// no OCR to do.
    ///
    /// Render DPI is intentionally modest (144 DPI ≈ 2× screen).
    /// Vision's text recogniser plateaus around that resolution
    /// on typical document fonts and going higher just inflates
    /// CGImage RAM (a single A4 page at 300 DPI is ~25 MB
    /// uncompressed — 50-page doc would peak at >1 GB if held
    /// simultaneously). We render one page at a time and let ARC
    /// release each before moving on.
    static func extractPagesWithOCRFallback(from url: URL) async throws -> [PageText] {
        // First try the textual fast path. Catch `extractionFailed`
        // specifically — anything else (fileNotReadable, unknown
        // format) is a permanent error and OCR can't help.
        do {
            return try extractPages(from: url)
        } catch DocumentError.extractionFailed {
            // Fall through to OCR for PDFs only.
        }

        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "pdf" else {
            // Non-PDF format produced no text — there's no OCR
            // path for plain text files; surface the original
            // error verbatim.
            throw DocumentError.extractionFailed
        }

        return try await ocrPDFPages(at: url)
    }

    #if canImport(UIKit)
    /// Per-page render + Vision OCR. Separated so the textual
    /// fast path doesn't pay the UIKit import cost when it isn't
    /// needed (also keeps the method body small enough to inline-
    /// read during review). UIKit-only — the rendering uses
    /// `UIGraphicsImageRenderer`. AppKit equivalent would need a
    /// different drawing context, out of scope for an iOS app.
    private static func ocrPDFPages(at url: URL) async throws -> [PageText] {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer { if isSecured { url.stopAccessingSecurityScopedResource() } }

        guard let pdf = PDFDocument(url: url) else {
            throw DocumentError.fileNotReadable
        }

        var pages: [PageText] = []
        pages.reserveCapacity(pdf.pageCount)

        for i in 0..<pdf.pageCount {
            // Per-page autoreleasepool. `renderPDFPage` allocates a
            // `UIGraphicsImageRenderer` + `UIImage` + `CGImage`; at
            // 144 DPI an A4 page is ~16 MB RGBA in pixels alone.
            // Without an explicit drain, those temporaries linger
            // until the surrounding async context unwinds — a
            // 50-page scan can otherwise peak past 800 MB dirty
            // pages and jetsam the app on iPhone.
            //
            // `autoreleasepool` can't bridge `try await` directly,
            // so the rendering (sync, the heavy allocator) happens
            // inside the pool and the OCR call (async, lightweight
            // wrapper around Vision) happens outside. ImageVision's
            // own temporaries are bounded — it's the per-page
            // CGImage that needs the drain.
            guard let page = pdf.page(at: i) else { continue }
            let cgImage: CGImage? = autoreleasepool {
                renderPDFPage(page)
            }
            guard let cgImage else { continue }
            let recognised: String
            do {
                recognised = try await ImageVisionService.extractText(fromCGImage: cgImage)
            } catch {
                // A single unreadable page (low contrast, blank
                // scan) shouldn't fail the whole document. Skip
                // it and continue — if *every* page fails we
                // surface ocrYieldedNothing below.
                continue
            }
            let trimmed = recognised.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            pages.append(PageText(pageNumber: i + 1, text: trimmed))
        }

        guard !pages.isEmpty else { throw DocumentError.ocrYieldedNothing }
        return pages
    }

    /// Renders a PDF page to a CGImage at ~144 DPI on a white
    /// background. White background matters for Vision: a
    /// transparent context produces a black-on-clear page that
    /// the recogniser handles fine in practice but loses contrast
    /// on faint scans.
    private static func renderPDFPage(_ page: PDFPage) -> CGImage? {
        let pageRect = page.bounds(for: .mediaBox)
        // PDF user-space unit is 1/72 inch; 144 DPI ⇒ scale 2.
        let scale: CGFloat = 2.0
        let target = CGSize(
            width: pageRect.width * scale,
            height: pageRect.height * scale
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // produce pixel-accurate target dims
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let uiImage = renderer.image { ctx in
            // Fill white so faint scans keep contrast.
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            // PDF coordinate space is bottom-left origin; flip
            // before drawing so the page renders upright.
            let cg = ctx.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: target.height)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
        return uiImage.cgImage
    }
    #else
    private static func ocrPDFPages(at url: URL) async throws -> [PageText] {
        // OCR fallback is UIKit-only. On non-UIKit platforms the
        // best we can do is surface the original error.
        throw DocumentError.extractionFailed
    }
    #endif

    /// Chunks large text into ~1000 character overlapping blocks.
    /// Drops trailing chunks shorter than `minChunkChars` so the
    /// in-line attachment path doesn't push junk fragments (single
    /// nav word, page-footer remnant) into the prompt's context
    /// budget — same hygiene `DocumentChunker` applies on the KB
    /// ingest path.
    static func chunk(text: String, chunkSize: Int = 1000, overlap: Int = 200) -> [String] {
        let minChunkChars = 40
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var chunks: [String] = []
        var currentChunk: [String] = []
        var currentLength = 0

        for word in words {
            currentChunk.append(word)
            currentLength += word.count + 1
            if currentLength >= chunkSize {
                let joined = currentChunk.joined(separator: " ")
                if joined.count >= minChunkChars {
                    chunks.append(joined)
                }
                // Keep the last few words for overlap
                let overlapCount = max(1, currentChunk.count / 5)
                currentChunk = Array(currentChunk.suffix(overlapCount))
                currentLength = currentChunk.joined(separator: " ").count
            }
        }
        if !currentChunk.isEmpty {
            let tail = currentChunk.joined(separator: " ")
            if tail.count >= minChunkChars { chunks.append(tail) }
        }
        return chunks
    }
}
