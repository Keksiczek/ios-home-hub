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

/// Manifest snapshot returned by `fetchModelManifest`. Pairs the
/// filtered file list with the upstream commit SHA so callers that
/// care about reproducibility (custom user-added MLX models, future
/// "model has updates available" UI) can pin / compare without a
/// second round trip.
struct HFModelManifest: Sendable {
    let files: [HFFileEntry]
    /// HEAD commit hash of the repo at the moment of fetch. `nil` if
    /// the API response omitted the `sha` field (rare; legacy repos).
    let sha: String?
}

struct HFModelSearchItem: Codable, Sendable {
    let id: String
    let author: String?
    let downloads: Int
    let likes: Int
    let tags: [String]?
    let pipelineTag: String?
    let siblings: [HFFileEntry]?

    private enum CodingKeys: String, CodingKey {
        case id, author, downloads, likes, tags
        case pipelineTag = "pipeline_tag"
        case siblings
    }
}

private struct HFModelInfo: Codable {
    let siblings: [HFFileEntry]
    /// Optional in the API response; old or unverified repos may
    /// omit it. Decoded as Optional so a missing key doesn't fail
    /// the whole metadata fetch.
    let sha: String?
}

/// Typed errors emitted by `HuggingFaceAPIClient`. We keep the wire-level
/// `URLError` for genuine network failures and surface application-level
/// HTTP failures here so callers can branch without parsing message
/// strings. The catalog UI needs to distinguish "gated repo, sign in"
/// from "rate limited, retry" from "no such repo" — string-matching on
/// the localized description is fragile and would break under
/// localization.
enum HFError: LocalizedError {
    /// The repository requires authentication (HTTP 401) or accepted
    /// terms (HTTP 403). Carries the repoId so the UI can show a
    /// "Open on Hugging Face" CTA without a second lookup.
    case gatedRepository(repoId: String, status: Int)
    /// The repository or file doesn't exist (404). Distinct from gated
    /// because the user action is different — they need to pick a
    /// different repo, not sign in.
    case notFound(repoId: String)

    var errorDescription: String? {
        switch self {
        case .gatedRepository(let id, let status):
            return "Repozitář \(id) je chráněný (HTTP \(status)) — vyžaduje přihlášení nebo přijetí licence na Hugging Face."
        case .notFound(let id):
            return "Repozitář \(id) na Hugging Face neexistuje."
        }
    }

    /// `true` for 401/403 — surfaced via this convenience so the catalog
    /// view can flag the model with a "Needs auth" badge.
    var isGated: Bool {
        if case .gatedRepository = self { return true }
        return false
    }

    /// Single source of truth for converting an HF-shaped HTTP failure
    /// into a user-facing message. Used by both the manifest path
    /// (`fetchModelManifest` → `HFError` constructor → here) and the
    /// background download path (`MLXBackgroundDownloader`'s URL
    /// session delegate, which receives a raw status code instead of
    /// a thrown error). Keeping the dictionary in one place means a
    /// 401 mid-download and a 401 at manifest time say the same thing,
    /// and the `isAuthRelatedFailure` heuristic in ModelsView keeps
    /// matching both.
    static func reasonForHTTPStatus(_ status: Int, context: String) -> String {
        switch status {
        case 401, 403:
            return "Hugging Face odmítl požadavek (HTTP \(status)) — token zřejmě chybí, vypršel, nebo nemáš přijatou licenci. Otevři Nastavení → Hugging Face."
        case 404:
            return "Soubor / repozitář '\(context)' na Hugging Face neexistuje (HTTP 404). Byl pravděpodobně přejmenován nebo odstraněn."
        case 429:
            return "Hugging Face rate-limit (HTTP 429) pro '\(context)'. Zkus znovu za pár minut."
        default:
            return "Server vrátil HTTP \(status) pro '\(context)'."
        }
    }
}

/// Lightweight client for the public Hugging Face model-info REST API.
///
/// No authentication required for public `mlx-community` repos.
/// Timeout is intentionally short (10 s) — this is a small JSON metadata
/// call, not a weight download. Callers should fall back gracefully on error.
enum HuggingFaceAPIClient {

    private static let apiBase = "https://huggingface.co/api/models"
    private static let resolveBase = "https://huggingface.co"

    // MARK: - ETag-aware manifest cache
    //
    // HF responds with strong ETags on `/api/models/{repo}` and
    // honours `If-None-Match` with a 304 (no body) when the upstream
    // commit hasn't moved. Caching the last (etag, manifest) pair
    // means a re-fetch on the same network typically transfers ~0 KB
    // of body, just headers. The cache is in-memory only — losing it
    // on app restart costs one full manifest fetch, which is what
    // happens today anyway.

    private final class ManifestCacheEntry {
        let etag: String
        let manifest: HFModelManifest
        let storedAt: Date
        init(etag: String, manifest: HFModelManifest) {
            self.etag = etag
            self.manifest = manifest
            self.storedAt = Date()
        }
    }
    nonisolated(unsafe) private static let manifestCache: NSCache<NSString, ManifestCacheEntry> = {
        let c = NSCache<NSString, ManifestCacheEntry>()
        c.countLimit = 32   // typical install lifetime touches a handful of repos
        return c
    }()
    /// Entries older than this are treated as cold even if the ETag
    /// would still 304 — caps the staleness of the file list/SHA
    /// we surface to callers when the network is unavailable.
    private static let manifestCacheMaxAge: TimeInterval = 30 * 60

    // MARK: - Public API

    /// Fetches the list of files in an HF repo and returns only those
    /// needed to run MLX inference locally.
    ///
    /// Retries up to 3 times on transient errors (429/502/503/504, network
    /// connection lost / timed out) with exponential back-off + jitter:
    /// 500 ms, 1 s, 2 s. Honors the `Retry-After` header when present so
    /// HF's rate limiter dictates cadence directly. Non-transient errors
    /// (400/401/403/404, malformed JSON, missing repo) propagate
    /// immediately.
    ///
    /// - Parameter repoId: e.g. `"mlx-community/Llama-3.2-1B-Instruct-4bit"`
    /// - Throws: URLError or DecodingError on network / parse failure.
    static func fetchModelFiles(repoId: String) async throws -> [HFFileEntry] {
        guard let url = URL(string: "\(apiBase)/\(repoId)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)

        let maxAttempts = 3
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    if isTransientStatus(http.statusCode), attempt < maxAttempts {
                        let delaySec = retryDelay(
                            attempt: attempt,
                            retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
                        )
                        try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                        continue
                    }
                    switch http.statusCode {
                    case 401, 403:
                        throw HFError.gatedRepository(repoId: repoId, status: http.statusCode)
                    case 404:
                        throw HFError.notFound(repoId: repoId)
                    default:
                        throw URLError(
                            .badServerResponse,
                            userInfo: [NSLocalizedDescriptionKey:
                                "HF API returned HTTP \(http.statusCode) for \(repoId)"]
                        )
                    }
                }
                let info = try JSONDecoder().decode(HFModelInfo.self, from: data)
                return info.siblings.filter { isNeededForMLXInference($0.rfilename) }
            } catch let urlError as URLError where isTransientURLError(urlError) && attempt < maxAttempts {
                lastError = urlError
                let delaySec = retryDelay(attempt: attempt, retryAfterHeader: nil)
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                continue
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    /// Same as `fetchModelFiles` but also returns the upstream commit
    /// SHA. Use this variant when the caller wants to pin the version
    /// or detect upstream updates after install. Shares the retry
    /// loop / transient-status policy with `fetchModelFiles`.
    ///
    /// Conditional GET: when we have a cached `(etag, manifest)` for
    /// this repo and the cached entry is younger than `manifestCacheMaxAge`,
    /// the request includes `If-None-Match: <etag>`. A 304 response
    /// returns the cached manifest without re-parsing the body. A 200
    /// returns the fresh manifest and refreshes the cache.
    static func fetchModelManifest(repoId: String) async throws -> HFModelManifest {
        guard let url = URL(string: "\(apiBase)/\(repoId)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)
        let cacheKey = repoId as NSString
        let cachedEntry: ManifestCacheEntry? = {
            guard let e = manifestCache.object(forKey: cacheKey) else { return nil }
            if Date().timeIntervalSince(e.storedAt) > manifestCacheMaxAge {
                manifestCache.removeObject(forKey: cacheKey)
                return nil
            }
            return e
        }()
        if let cachedEntry {
            request.setValue(cachedEntry.etag, forHTTPHeaderField: "If-None-Match")
        }

        let maxAttempts = 3
        var attempt = 0
        var lastError: Error?
        while attempt < maxAttempts {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 304, let cachedEntry {
                        // Server confirmed our cached copy is still
                        // current. Returning the cached manifest
                        // (with its original storedAt) means callers
                        // see byte-identical results to the prior call.
                        return cachedEntry.manifest
                    }
                    if !(200..<300).contains(http.statusCode) {
                        if isTransientStatus(http.statusCode), attempt < maxAttempts {
                            let delaySec = retryDelay(
                                attempt: attempt,
                                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
                            )
                            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                            continue
                        }
                        switch http.statusCode {
                        case 401, 403:
                            throw HFError.gatedRepository(repoId: repoId, status: http.statusCode)
                        case 404:
                            throw HFError.notFound(repoId: repoId)
                        default:
                            throw URLError(
                                .badServerResponse,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "HF API returned HTTP \(http.statusCode) for \(repoId)"]
                            )
                        }
                    }
                }
                let info = try JSONDecoder().decode(HFModelInfo.self, from: data)
                let files = info.siblings.filter { isNeededForMLXInference($0.rfilename) }
                let manifest = HFModelManifest(files: files, sha: info.sha)
                if let http = response as? HTTPURLResponse,
                   let etag = http.value(forHTTPHeaderField: "ETag") {
                    manifestCache.setObject(
                        ManifestCacheEntry(etag: etag, manifest: manifest),
                        forKey: cacheKey
                    )
                }
                return manifest
            } catch let urlError as URLError where isTransientURLError(urlError) && attempt < maxAttempts {
                lastError = urlError
                let delaySec = retryDelay(attempt: attempt, retryAfterHeader: nil)
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                continue
            }
        }
        // Loop only exits successfully via `return`; if we fall through it
        // means every attempt threw with a non-transient error or the last
        // transient retry exhausted. Re-raise the last seen error so the
        // caller gets a real diagnostic, not a generic "out of attempts".
        throw lastError ?? URLError(.unknown)
    }

    /// Fetches a list of popular models from Hugging Face based on
    /// download count. If a `query` is provided, performs a free-text
    /// search. Otherwise scopes by `author` (defaults to
    /// `mlx-community`) so the result list contains repos the
    /// `HFModelMapper` can actually consume — generic HF repos rarely
    /// conform to MLX/GGUF on-device requirements.
    static func fetchPopularModels(
        query: String? = nil,
        author: String? = "mlx-community",
        limit: Int = 30
    ) async throws -> [HFModelSearchItem] {
        var urlString = apiBase
        if let query = query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            urlString += "?search=\(encodedQuery)&sort=downloads&direction=-1&limit=\(limit)&full=true"
        } else {
            let scopedAuthor = author ?? "mlx-community"
            urlString += "?author=\(scopedAuthor)&sort=downloads&direction=-1&limit=\(limit)&full=true"
        }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)

        let maxAttempts = 3
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    if isTransientStatus(http.statusCode), attempt < maxAttempts {
                        let delaySec = retryDelay(
                            attempt: attempt,
                            retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
                        )
                        try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                        continue
                    }
                    throw URLError(
                        .badServerResponse,
                        userInfo: [NSLocalizedDescriptionKey: "HF API returned HTTP \(http.statusCode) for search"]
                    )
                }
                return try JSONDecoder().decode([HFModelSearchItem].self, from: data)
            } catch let urlError as URLError where isTransientURLError(urlError) && attempt < maxAttempts {
                lastError = urlError
                let delaySec = retryDelay(attempt: attempt, retryAfterHeader: nil)
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                continue
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    // MARK: - Authorization

    /// Stamps the `Authorization: Bearer <token>` header on `request` when
    /// the user has saved a Hugging Face token via `HFTokenStore`. No-op
    /// otherwise — anonymous requests continue to work for public repos.
    /// Centralised here so manifest, file-list, and any future endpoints
    /// stay consistent; missing the header on one call site is exactly
    /// the failure mode that produced the original 401 spam.
    static func applyAuthorization(to request: inout URLRequest) {
        if let token = HFTokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Result of probing the `/api/whoami-v2` endpoint with the supplied
    /// token. Surfaced to Settings so the user gets immediate feedback
    /// ("✓ Přihlášeno jako stepan") instead of finding out the token is
    /// wrong only when their first download fails 30 s later.
    enum TokenValidation: Sendable, Equatable {
        /// Token authenticated. `username` is the human-readable handle
        /// HF echoed back — display verbatim, don't try to derive it
        /// from the token itself.
        case valid(username: String)
        /// HF rejected the token (401). Either the user pasted a wrong
        /// value, the token has been revoked, or the prefix is "hf_" but
        /// the rest is invalid.
        case invalid
        /// Network call failed before we could classify the response.
        /// Treated separately from `.invalid` so the user knows the
        /// token might be fine and they should retry on Wi-Fi.
        case networkError(String)
    }

    /// Single-shot probe against `https://huggingface.co/api/whoami-v2`.
    /// Doesn't read `HFTokenStore`; the caller passes the candidate
    /// token explicitly so the Settings UI can validate *before* it
    /// persists (avoids a save-then-revert round trip on bad input).
    ///
    /// Timeout: 5 s. The endpoint is a tiny JSON object; if we don't
    /// hear back in 5 s the user is on a flaky network and they'll
    /// retry anyway.
    static func validateToken(_ token: String) async -> TokenValidation {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }
        guard let url = URL(string: "https://huggingface.co/api/whoami-v2") else {
            return .networkError("Bad URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .networkError("Bad response")
            }
            switch http.statusCode {
            case 200:
                // Minimal struct — HF returns ~20 fields but we only
                // need the handle. Decode opportunistically so a
                // schema change on HF's side downgrades to "valid but
                // unknown name" rather than a hard failure.
                struct Who: Decodable { let name: String? }
                let who = try? JSONDecoder().decode(Who.self, from: data)
                return .valid(username: who?.name ?? "?")
            case 401, 403:
                return .invalid
            default:
                return .networkError("HTTP \(http.statusCode)")
            }
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    // MARK: - Retry helpers

    /// HTTP status codes that warrant a retry. Distinct from "errors we
    /// surface to the user" — 5xx are transient backend failures, 429
    /// is rate-limit (HF returns this when the unauth quota is exceeded).
    private static func isTransientStatus(_ code: Int) -> Bool {
        return code == 429 || code == 502 || code == 503 || code == 504
    }

    /// URLError codes corresponding to "network is flapping; retry might
    /// succeed". Excludes auth / DNS / bad URL — those are sticky.
    private static func isTransientURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Returns the next back-off delay in seconds.
    /// Honors `Retry-After` (integer seconds OR HTTP-date) if the server
    /// supplied one — that signal is authoritative. Otherwise uses
    /// exponential back-off (0.5 s, 1 s, 2 s) with up to ±20 % jitter to
    /// avoid synchronised retry storms when multiple clients restart at
    /// the same moment.
    private static func retryDelay(attempt: Int, retryAfterHeader: String?) -> Double {
        if let header = retryAfterHeader {
            if let seconds = Double(header.trimmingCharacters(in: .whitespaces)) {
                return min(max(seconds, 0.5), 30)
            }
            // HTTP-date form: "Retry-After: Wed, 21 Oct 2026 07:28:00 GMT"
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            if let date = fmt.date(from: header) {
                let delta = max(0.5, date.timeIntervalSinceNow)
                return min(delta, 30)
            }
        }
        let base = 0.5 * pow(2.0, Double(attempt - 1))
        let jitter = Double.random(in: 0.8...1.2)
        return min(base * jitter, 10)
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
