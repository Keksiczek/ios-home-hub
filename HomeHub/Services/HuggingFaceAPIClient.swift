import Foundation

/// File entry returned by the Hugging Face model-info API.
struct HFFileEntry: Codable, Sendable {
    let rfilename: String
    /// Uncompressed size in bytes. Nil when the API omits it (LFS pointer not resolved).
    let size: Int64?

    private enum CodingKeys: String, CodingKey {
        case rfilename
        case size
    }
}

private struct HFModelInfo: Codable {
    let siblings: [HFFileEntry]
}

/// Lightweight client for the public Hugging Face model-info REST API.
///
/// No authentication required for public `mlx-community` repos.
/// Timeout is intentionally short (10 s) — this is a small JSON metadata
/// call, not a weight download. Callers should fall back gracefully on error.
enum HuggingFaceAPIClient {

    private static let apiBase = "https://huggingface.co/api/models"
    private static let resolveBase = "https://huggingface.co"

    // MARK: - Public API

    /// Fetches the list of files in an HF repo and returns only those
    /// needed to run MLX inference locally.
    ///
    /// - Parameter repoId: e.g. `"mlx-community/Llama-3.2-1B-Instruct-4bit"`
    /// - Throws: URLError or DecodingError on network / parse failure.
    static func fetchModelFiles(repoId: String) async throws -> [HFFileEntry] {
        guard let url = URL(string: "\(apiBase)/\(repoId)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(
                .badServerResponse,
                userInfo: [NSLocalizedDescriptionKey:
                    "HF API returned HTTP \(http.statusCode) for \(repoId)"]
            )
        }
        let info = try JSONDecoder().decode(HFModelInfo.self, from: data)
        return info.siblings.filter { isNeededForMLXInference($0.rfilename) }
    }

    /// Direct-download URL for a single file in an HF repo.
    /// Format: `https://huggingface.co/{repoId}/resolve/main/{filename}`
    static func downloadURL(repoId: String, filename: String) -> URL {
        // URL(string:) won't encode spaces in a pre-built string — use
        // components so the path is percent-encoded correctly.
        var comps = URLComponents(string: resolveBase)!
        comps.path = "/\(repoId)/resolve/main/\(filename)"
        return comps.url ?? URL(string: "\(resolveBase)/\(repoId)/resolve/main/\(filename)")!
    }

    // MARK: - File filter

    /// Returns `true` for files that `mlx-lm` / `MLXLMCommon` requires to
    /// run inference. Rejects non-MLX weights and documentation.
    static func isNeededForMLXInference(_ filename: String) -> Bool {
        let name = filename.lowercased()

        // ── Reject ─────────────────────────────────────────────────────────
        // Non-MLX weight formats
        if name.hasPrefix("pytorch_model") || name.hasPrefix("flax_model") ||
           name.hasPrefix("tf_model") { return false }
        // Developer / documentation artefacts
        let rejectSuffixes = [".py", ".md", ".ipynb", ".txt", ".sh"]
        if rejectSuffixes.contains(where: { name.hasSuffix($0) }) { return false }
        // Raw PyTorch / ONNX files
        if name.hasSuffix(".bin") || name.hasSuffix(".pt") ||
           name.hasSuffix(".onnx") { return false }

        // ── Accept ─────────────────────────────────────────────────────────
        // MLX weight shards and their index
        if name.hasSuffix(".safetensors") || name.hasSuffix(".safetensors.index.json") {
            return true
        }
        // Essential JSON configs (exact names, case-insensitive)
        let essentialJSON: Set<String> = [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "generation_config.json",
            "vocab.json",
            "added_tokens.json",
        ]
        if essentialJSON.contains(name) { return true }
        // BPE tokeniser files (SmolLM2, GPT-2-family)
        if name == "merges.txt" || name == "vocab.bpe" { return true }
        // SentencePiece tokeniser model (Gemma)
        if name.hasSuffix(".model") && (name.contains("tokenizer") || name.contains("spiece")) {
            return true
        }

        return false
    }
}
