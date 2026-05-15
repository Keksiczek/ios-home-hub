import Foundation
import PDFKit

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

        var errorDescription: String? {
            switch self {
            case .fileNotReadable:
                return "Soubor nelze přečíst nebo k němu není přístup."
            case .unknownFormat(let ext):
                let hint = ext.isEmpty ? "Soubor nemá příponu." : ".\(ext) není podporován."
                return "Tento formát souboru zatím není podporován. \(hint) Podporované formáty: PDF, TXT, MD, CSV, JSON."
            case .extractionFailed:
                return "Z dokumentu se nepodařilo extrahovat žádný text. Nejspíš jde o naskenovaný PDF bez textové vrstvy — zatím nepodporujeme OCR."
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
