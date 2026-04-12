import Foundation
import PDFKit

/// Service responsible for extracting text from local files (PDFs, TXT, MD, etc.)
enum DocumentReaderService {
    
    enum DocumentError: Error, LocalizedError {
        case fileNotReadable
        case unknownFormat
        case extractionFailed
        
        var errorDescription: String? {
            switch self {
            case .fileNotReadable: return "Soubor nelze přečíst nebo k němu není přístup."
            case .unknownFormat: return "Tento formát souboru zatím není podporován."
            case .extractionFailed: return "Z dokumentu se nepodařilo extrahovat žádný text."
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
            throw DocumentError.unknownFormat
        }
    }
    
    /// Chunks large text into ~1000 character overlapping blocks.
    static func chunk(text: String, chunkSize: Int = 1000, overlap: Int = 200) -> [String] {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var chunks: [String] = []
        var currentChunk: [String] = []
        var currentLength = 0
        
        for word in words {
            currentChunk.append(word)
            currentLength += word.count + 1
            if currentLength >= chunkSize {
                chunks.append(currentChunk.joined(separator: " "))
                // Keep the last few words for overlap
                let overlapCount = max(1, currentChunk.count / 5)
                currentChunk = Array(currentChunk.suffix(overlapCount))
                currentLength = currentChunk.joined(separator: " ").count
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.joined(separator: " "))
        }
        return chunks
    }
}
