import Foundation

/// Pure utility to map Hugging Face search results (from the REST API)
/// to `LocalModel` records.
enum HFModelMapper {

    /// Maps a raw API search result to a valid `LocalModel` structure.
    static func mapToLocalModel(item: HFModelSearchItem) -> LocalModel {
        let repoId = item.id
        
        // 1. Calculate file size by summing all files needed for MLX inference
        var totalBytes: Int64 = 0
        if let siblings = item.siblings {
            let filtered = siblings.filter { HuggingFaceAPIClient.isNeededForMLXInference($0.rfilename) }
            totalBytes = filtered.reduce(0) { $0 + ($1.size ?? 0) }
        }
        
        // 2. Parse display name
        let cleanName = repoId.replacingOccurrences(of: "mlx-community/", with: "")
                              .replacingOccurrences(of: "-", with: " ")
                              .replacingOccurrences(of: "_", with: " ")
        
        // 3. Detect model family
        let family = detectFamily(repoId: repoId, tags: item.tags)
        
        // 4. Parse parameter count
        let parameterCount = parseParameterCount(name: cleanName, tags: item.tags)
        
        // 5. Parse quantization
        let quantization = parseQuantization(name: cleanName, tags: item.tags)
        
        // 6. Parse license
        let license = parseLicense(tags: item.tags)
        
        // 7. Choose a safe context length default
        let contextLength = defaultContextLength(family: family)
        
        // 8. Determine device recommendation (heavy models >= 6B active params are iPad-only)
        let recommendedFor: [DeviceClass] = isHeavyModel(parameterCount: parameterCount) ? [.iPadMSeries] : [.iPhone, .iPadMSeries]
        
        // 9. Determine authorization requirement (known gated repos/authors)
        let requiresAuth = isGatedRepository(repoId: repoId, tags: item.tags)
        
        // 10. Construct the download URL
        let downloadURL = URL(string: "https://huggingface.co/\(repoId)") ?? URL(static: "https://huggingface.co")
        
        return LocalModel(
            id: repoId,
            displayName: cleanName,
            family: family,
            parameterCount: parameterCount,
            quantization: quantization,
            sizeBytes: totalBytes,
            contextLength: contextLength,
            downloadURL: downloadURL,
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: recommendedFor,
            license: license,
            backend: .mlx,
            format: .mlx,
            isUserAdded: true, // Marked so it registers in user-models.json on download
            installedRepoSHA: nil,
            requiresAuth: requiresAuth,
            downloads: item.downloads,
            likes: item.likes
        )
    }

    // MARK: - Parse Helpers

    private static func detectFamily(repoId: String, tags: [String]?) -> String {
        let text = (repoId + " " + (tags?.joined(separator: " ") ?? "")).lowercased()
        if text.contains("llama")    { return "Llama" }
        if text.contains("gemma3n")  { return "Gemma3n" }
        if text.contains("gemma3")   { return "Gemma3" }
        if text.contains("gemma2")   { return "Gemma2" }
        if text.contains("gemma")    { return "Gemma3" }
        if text.contains("qwen")     { return "Qwen" }
        if text.contains("phi")      { return "Phi" }
        if text.contains("mistral")  { return "Mistral" }
        if text.contains("smollm")   { return "SmolLM2" }
        return "Custom"
    }

    private static func parseParameterCount(name: String, tags: [String]?) -> String {
        // Try parsing from display name first (e.g. "3.2 3B Instruct" -> "3B")
        let pattern = #"\b\d+(\.\d+)?[mMgG]\b"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)),
           let range = Range(match.range, in: name) {
            return String(name[range]).uppercased()
        }
        
        // Try parsing from tags next
        if let tags = tags {
            for tag in tags {
                if tag.hasSuffix("b") || tag.hasSuffix("m") {
                    let numPart = tag.dropLast()
                    if Double(numPart) != nil {
                        return tag.uppercased()
                    }
                }
            }
        }
        return "Unknown"
    }

    private static func parseQuantization(name: String, tags: [String]?) -> String {
        let lcName = name.lowercased()
        if lcName.contains("4bit") || lcName.contains("q4") || lcName.contains("int4") {
            return "4-bit"
        }
        if lcName.contains("8bit") || lcName.contains("q8") || lcName.contains("int8") {
            return "8-bit"
        }
        if lcName.contains("3bit") || lcName.contains("q3") {
            return "3-bit"
        }
        if lcName.contains("2bit") || lcName.contains("q2") {
            return "2-bit"
        }
        
        // Scan tags
        if let tags = tags {
            for tag in tags {
                let lcTag = tag.lowercased()
                if lcTag.contains("4bit") { return "4-bit" }
                if lcTag.contains("8bit") { return "8-bit" }
                if lcTag.contains("3bit") { return "3-bit" }
            }
        }
        return "4-bit" // Default to 4-bit as it is standard for on-device MLX community builds
    }

    private static func parseLicense(tags: [String]?) -> String {
        guard let tags = tags else { return "Unknown" }
        for tag in tags {
            if tag.hasPrefix("license:") {
                return tag.replacingOccurrences(of: "license:", with: "").uppercased()
            }
        }
        return "Unknown"
    }

    private static func defaultContextLength(family: String) -> Int {
        switch family {
        case "Phi", "SmolLM2":
            return 1024
        default:
            return 2048
        }
    }

    private static func isHeavyModel(parameterCount: String) -> Bool {
        let clean = parameterCount.uppercased()
        guard clean.hasSuffix("B") else { return false }
        let numStr = clean.dropLast()
        if let size = Double(numStr), size >= 6.0 {
            return true
        }
        return false
    }

    private static func isGatedRepository(repoId: String, tags: [String]?) -> Bool {
        let lcRepo = repoId.lowercased()
        if lcRepo.contains("meta-llama") || lcRepo.contains("google/gemma") {
            return true
        }
        if let tags = tags {
            for tag in tags {
                let lcTag = tag.lowercased()
                if lcTag.contains("gated") || lcTag.contains("license:llama") {
                    return true
                }
            }
        }
        return false
    }
}
