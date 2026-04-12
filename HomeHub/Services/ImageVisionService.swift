import Foundation
import Vision
#if canImport(UIKit)
import UIKit
#endif

enum ImageVisionService {
    enum VisionError: Error, LocalizedError {
        case invalidImage
        case extractionFailed
        
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "Obrázek se nepodařilo načíst pro analýzu."
            case .extractionFailed: return "Nebylo možné rozpoznat žádný text v obrázku."
            }
        }
    }
    
    /// Extracts text from an image at the given URL using Apple's Vision framework.
    static func extractText(from url: URL) async throws -> String {
        // Access security scoped resource just in case it came from a picker
        let isSecured = url.startAccessingSecurityScopedResource()
        defer {
            if isSecured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw VisionError.invalidImage
        }
        
        return try await extractText(from: cgImage)
    }
    
    #if canImport(UIKit)
    static func extractText(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw VisionError.invalidImage
        }
        return try await extractText(from: cgImage)
    }
    #endif
    
    private static func extractText(from cgImage: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(throwing: VisionError.extractionFailed)
                    return
                }
                
                let extractedStrings = observations.compactMap { observation in
                    // Grab the top candidate
                    observation.topCandidates(1).first?.string
                }
                
                let fullText = extractedStrings.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                
                if fullText.isEmpty {
                    continuation.resume(throwing: VisionError.extractionFailed)
                } else {
                    continuation.resume(returning: fullText)
                }
            }
            
            // Prefer fast/accurate based on need, .accurate is usually best for OCR
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Support Czech and English
            request.recognitionLanguages = ["cs-CZ", "en-US"]
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
