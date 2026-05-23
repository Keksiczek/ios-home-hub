import Foundation
import SwiftUI
import os
import CryptoKit

/// Handles downloading a `LocalModel` to disk and keeping the
/// catalog's `installState` in sync.
///
/// ## Pipeline overview (unified for curated catalog + `Add from URL`)
///
/// Both entry points funnel through `start(_:)` → `realDownload()`.
/// The pipeline runs the following steps:
///
/// 1. Write bytes into `LocalModelService.localURL(for:)` (Application
///    Support / Models / `<id>.gguf`), using an atomic move from a temp
///    file. The runtime reads from this exact same path.
/// 2. Validate the file (GGUF magic header check, optional SHA-256).
/// 3. Flip `ModelCatalogService.installState` to `.installed(localURL:)`.
/// 4. Invoke `onModelInstalled` so `AppContainer` can auto-activate the
///    model the first time the user has no active selection.
///
/// Real `URLSession` downloads with progress tracking via delegate,
/// SHA-256 verification, and cancel support.
@MainActor
final class ModelDownloadService: ObservableObject {

    // MARK: - Download phase

    /// Granular phase within an active download, surfaced in the UI so the
    /// user always knows what is happening.
    enum DownloadPhase: Equatable {
        case preparing
        case downloading
        case validating
        case installing

        var label: String {
            switch self {
            case .preparing:   return "Preparing…"
            case .downloading: return "Downloading"
            case .validating:  return "Validating…"
            case .installing:  return "Installing…"
            }
        }
    }

    struct DownloadState: Equatable {
        var modelID: String
        var progress: Double
        var isCancelled: Bool
        var phase: DownloadPhase = .preparing
    }

    @Published private(set) var active: [String: DownloadState] = [:]

    /// OSSignposter for the download lifecycle. Opening an interval
    /// per modelID at `start(_:)` / `startMLXDownload(_:)` and closing
    /// it from the install-success or failure callbacks gives the
    /// Xcode Instruments timeline a single contiguous bar per
    /// download — far easier to debug "stuck at 95 %" reports than
    /// the textual log. Interval state map kept here so we can call
    /// `endInterval` even when the success / failure callbacks are
    /// far from the start site.
    private let signposter = OSSignposter(
        subsystem: "com.homehub.app",
        category: "ModelDownload"
    )
    private var signpostIntervals: [String: OSSignpostIntervalState] = [:]

    /// Opens a signpost interval for this model. No-op if one is
    /// already open (defensive — repeated starts shouldn't double-tag).
    private func beginDownloadSignpost(_ modelID: String) {
        guard signpostIntervals[modelID] == nil else { return }
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval(
            "Download",
            id: signpostID,
            "modelID=\(modelID, privacy: .public)"
        )
        signpostIntervals[modelID] = state
    }

    /// Closes the signpost interval for this model with a final
    /// outcome tag (`success` / `failed` / `cancelled`). Idempotent.
    private func endDownloadSignpost(_ modelID: String, outcome: String) {
        guard let state = signpostIntervals.removeValue(forKey: modelID) else { return }
        signposter.endInterval("Download", state, "outcome=\(outcome, privacy: .public)")
    }

    /// Per-modelID sidecar map carrying the upstream commit SHA from
    /// the manifest fetch through to the install-success callback,
    /// where the catalog pin gets written. Cleared when the install
    /// finishes (success OR failure) so a re-download starts clean.
    /// Kept off `DownloadState` to avoid bleeding MLX-only metadata
    /// into the shared GGUF/MLX progress struct.
    private var pendingRepoSHAs: [String: String] = [:]

    /// Per-modelID expected total cache bytes from the manifest at
    /// download-start time. Captured so the completion-side validator
    /// can compare against `mlxCacheSizeBytes(for:)` and reject a
    /// download that was structurally complete (config + tokenizer +
    /// safetensors all present, passed `inspectMLXCache`) yet
    /// noticeably smaller than what the manifest promised — the
    /// classic signature of one or more LFS shards being truncated
    /// without an error from the underlying transport (HTTP
    /// chunked-encoding aborts, sandbox quota hit mid-stream, etc.).
    ///
    /// A full SHA-256 verification would need the HF blobs API or
    /// X-Linked-Etag interception; size-based matching is the
    /// pragmatic substitute that catches the most common corruption
    /// mode (partial bytes) with no extra network round-trip.
    /// Tolerance of 1 % below expected — covers compression /
    /// filesystem-attribute differences without admitting truncation.
    private var pendingManifestTotals: [String: Int64] = [:]

    /// User-visible error message from the most recent destructive
    /// operation (currently: `deleteModel`). Set when an underlying
    /// FileManager / catalog mutation throws; cleared by
    /// `acknowledgeDeleteError()` when the user dismisses the alert.
    /// Surfaced as a one-shot alert in the Models screen — previously
    /// the error was only logged, so a "Delete" tap that silently
    /// failed left the model lingering with no explanation.
    @Published var lastDeleteError: String?

    /// UI hook — clears the alert after the user taps OK.
    func acknowledgeDeleteError() { lastDeleteError = nil }

    /// Wall-clock duration past which a partial / broken artefact on
    /// disk (resume blob, broken MLX cache directory) is considered
    /// stale and safe to remove. 7 days is the sweet spot:
    ///   * **Long enough** that a user who started a multi-GB download
    ///     on the train and didn't open the app until next weekend
    ///     still has their resume data intact.
    ///   * **Short enough** that a download attempt that failed
    ///     silently last month doesn't keep nagging the user with a
    ///     stale "Paused" badge or eating disk space they can't
    ///     recover from the UI.
    /// Used by both `pruneStaleResumeData` and `pruneBrokenMLXCaches`
    /// so the two retention policies stay aligned automatically.
    static let staleArtefactTTL: TimeInterval = 7 * 24 * 60 * 60

    /// Called on the main actor after a model successfully transitions to
    /// `.installed`. `AppContainer` wires this up to auto-activate the first
    /// installed model when the user hasn't picked one yet — otherwise a
    /// fresh download could never flip `runtime.activeModel != nil` without
    /// the user finding and tapping "Load" manually.
    var onModelInstalled: ((LocalModel) async -> Void)?

    private let localModels: LocalModelService
    private let catalog: ModelCatalogService
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Background multi-file downloader for MLX weight repos.
    let mlxDownloader: MLXBackgroundDownloader

    private let log = Logger(subsystem: "com.homehub.app", category: "ModelDownloadService")

    init(
        localModels: LocalModelService,
        catalog: ModelCatalogService,
        mlxDownloader: MLXBackgroundDownloader = .shared
    ) {
        self.localModels = localModels
        self.catalog = catalog
        self.mlxDownloader = mlxDownloader
        setupCoordinatorCallbacks()
    }

    func isDownloading(_ modelID: String) -> Bool {
        active[modelID] != nil || DownloadManager.shared.isActive(modelID)
    }

    /// Returns `true` when a previous download was interrupted and resume
    /// data is available. The UI shows a "Paused" badge in this state.
    func hasResumeData(for modelID: String) -> Bool {
        UserDefaults.standard.data(
            forKey: resumeDataKey(for: modelID)
        ) != nil
    }

    func start(_ model: LocalModel) {
        guard active[model.id] == nil else { return }

        // A background URLSession task can still be in-flight after an OS
        // relaunch even though the in-memory `active` map is empty. Re-
        // entering `start()` in that state would enqueue a duplicate task
        // pointing at the same destination file — both writers would race
        // through `completeInstall()` and trample each other's output.
        // Reconcile observable state instead and bail.
        if DownloadManager.shared.isActive(model.id) {
            log.notice("start(): '\(model.id, privacy: .public)' already has an in-flight background task — reattaching, not enqueuing a duplicate")
            active[model.id] = DownloadState(modelID: model.id, progress: 0, isCancelled: false, phase: .downloading)
            return
        }

        // Open the Instruments-visible interval for this download.
        // Endpoints live in the install-success / cancel / fail paths
        // below so the bar in the timeline matches the user-visible
        // lifecycle exactly.
        beginDownloadSignpost(model.id)

        // Disk-space preflight — catch the "user tries to download a 4 GB
        // model onto a full phone" case before the URLSession task starts
        // and silently fails mid-stream with a cryptic NSPOSIXErrorDomain.
        // Skipped when `sizeBytes == 0` (user-added models via URL often
        // don't know their size in advance).
        if model.sizeBytes > 0,
           let free = Self.availableDiskSpaceBytes(),
           free < model.sizeBytes {
            let err = DownloadError.insufficientDiskSpace(
                required: model.sizeBytes,
                available: free
            )
            log.error("Preflight failed for '\(model.id, privacy: .public)': \(err.errorDescription ?? "", privacy: .public)")
            catalog.setInstallState(.failed(reason: err.errorDescription ?? "Insufficient disk space"), for: model.id)
            return
        }

        active[model.id] = DownloadState(modelID: model.id, progress: 0, isCancelled: false, phase: .preparing)
        catalog.setInstallState(.downloading(progress: 0), for: model.id)
        log.info("Starting download for model '\(model.id, privacy: .public)' from \(model.downloadURL.absoluteString, privacy: .public)")

        tasks[model.id] = Task { [weak self] in
            await self?.realDownload(model: model)
        }
    }

    /// Returns the space iOS considers available for important (user-
    /// initiated) downloads on the Application Support volume. Uses
    /// `volumeAvailableCapacityForImportantUsageKey` per Apple's
    /// guidance — this is larger than raw free bytes because iOS will
    /// purge purgeable caches to satisfy the request.
    private static func availableDiskSpaceBytes() -> Int64? {
        let url = URL.applicationSupportDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func cancel(_ modelID: String) {
        active[modelID]?.isCancelled = true
        tasks[modelID]?.cancel()
        tasks[modelID] = nil
        active[modelID] = nil
        // Drop any pending SHA sidecar so a re-download with a different
        // upstream revision can't accidentally inherit the stale pin.
        pendingRepoSHAs.removeValue(forKey: modelID)
        pendingManifestTotals.removeValue(forKey: modelID)
        endDownloadSignpost(modelID, outcome: "cancelled")
        DownloadManager.shared.cancel(modelID: modelID)
        catalog.setInstallState(.notInstalled, for: modelID)
        // Clean up any partial MLX cache so a subsequent Download starts
        // from a clean slate. Best-effort — a no-op for GGUF and for
        // models with no cache yet.
        if let model = catalog.model(withID: modelID),
           model.format == .mlx,
           let repoId = model.repoId {
            Task { [localModels, log] in
                do {
                    try await localModels.removeMLXCache(for: repoId)
                    log.info("Cancelled: cleaned MLX cache for '\(modelID, privacy: .public)'")
                } catch {
                    log.notice("Cancelled: MLX cache cleanup skipped for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        log.info("Cancelled download for '\(modelID, privacy: .public)'")
    }

    /// Deletes a model's file from disk, unloads it from the runtime if active,
    /// and removes user-added models from the catalog entirely.
    ///
    /// - Parameter modelID: The ID of the model to delete.
    /// - Parameter runtime: The runtime manager used to unload an active model.
    func deleteModel(_ modelID: String, runtime: RuntimeManager) async {
        // Can't delete while a download is in progress — cancel it first.
        if active[modelID] != nil {
            cancel(modelID)
        }

        // Unload from runtime if this is the currently active model.
        if runtime.activeModel?.id == modelID {
            await runtime.unload()
        }

        // Remove file or MLX cache from disk. Failure here used to be
        // silent (logged only) — the model would vanish from the
        // catalog while its on-disk artefacts lingered, eating
        // gigabytes the user couldn't recover from UI. Now we both
        // log AND surface a one-shot alert via `lastDeleteError`.
        do {
            if let model = catalog.model(withID: modelID), model.format == .mlx, let repoId = model.repoId {
                try await localModels.removeMLXCache(for: repoId)
            } else {
                try await localModels.remove(modelID)
            }
        } catch {
            log.error("Failed to remove model file for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            let displayName = catalog.model(withID: modelID)?.displayName ?? modelID
            lastDeleteError = "Nepodařilo se smazat '\(displayName)': \(error.localizedDescription)"
        }

        // Update catalog: user-added models are removed entirely; curated models
        // just revert to .notInstalled so the user can re-download them.
        if catalog.model(withID: modelID)?.isUserAdded == true {
            catalog.removeUserModel(id: modelID)
        } else {
            catalog.setInstallState(.notInstalled, for: modelID)
        }
    }

    /// Creates a user-defined model from a direct URL and starts downloading it.
    ///
    /// The model is added to the catalog with `isUserAdded = true` and persisted
    /// in `user-models.json`. The download uses the **same pipeline** as curated
    /// models — `start(_:)` → URLSession/simulate → GGUF validation → install.
    ///
    /// - Parameters:
    ///   - name: Display name chosen by the user (must be non-empty).
    ///   - url: Direct HTTPS/HTTP download URL for the .gguf file.
    ///   - contextLength: Context window size; defaults to 4096 if unknown.
    /// - Throws: `URLImportError.invalidName` / `.invalidURL` when inputs are rejected.
    /// Result of a pre-download URL probe. Surfaced in the import sheet
    /// so the user gets fast feedback ("285 MB, valid GGUF") instead of
    /// waiting for a full download to fail validation.
    struct URLProbe: Equatable, Sendable {
        var sizeBytes: Int64?
        var isGGUF: Bool
        var suggestedName: String?
        var statusCode: Int
        var detail: String?
    }

    /// Performs a HEAD + Range-GET to validate a candidate model URL
    /// without downloading the whole file. Returns:
    ///   * `sizeBytes` from `Content-Length` (used for disk-space preflight)
    ///   * `isGGUF` from the first 4 bytes — the GGUF magic header
    ///   * `suggestedName` derived from the URL's last path component
    ///
    /// Throws on transport errors or non-2xx status codes; the sheet
    /// renders the message verbatim. HF gated models return 401 here, so
    /// the user sees "Gated repo — needs auth" instead of a cryptic
    /// validation failure 5 minutes into a 4 GB download.
    nonisolated static func probeURL(_ rawURL: URL) async throws -> URLProbe {
        let url = Self.normaliseModelURL(rawURL)
        try Self.validateModelURL(url)

        // HEAD first — most servers respect it and we get Content-Length
        // without burning bytes. HF actually serves Content-Length from
        // GETs only; a few CDNs reject HEAD entirely. The Range fallback
        // below picks up the slack.
        var headRequest = URLRequest(url: url, timeoutInterval: 10)
        headRequest.httpMethod = "HEAD"
        headRequest.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        var sizeFromHead: Int64?
        var statusCode = 0
        do {
            let (_, response) = try await URLSession.shared.data(for: headRequest)
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                if let len = http.value(forHTTPHeaderField: "Content-Length"),
                   let parsed = Int64(len) {
                    sizeFromHead = parsed
                }
            }
        } catch {
            // Some servers (Cloudflare in particular) reject HEAD with
            // a 400/403 — fall through to the Range probe rather than
            // giving up. The Range request gives us both validation and
            // a size from `Content-Range: bytes 0-3/<total>`.
        }

        // Range-GET for the first 4 bytes. Doubles as a connectivity
        // check AND a GGUF validation in a single request — typically
        // returns in under 200 ms on Wi-Fi.
        var rangeRequest = URLRequest(url: url, timeoutInterval: 10)
        rangeRequest.httpMethod = "GET"
        rangeRequest.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        rangeRequest.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: rangeRequest)
        var size = sizeFromHead
        var isGGUF = false
        var detail: String?

        if let http = response as? HTTPURLResponse {
            statusCode = http.statusCode
            // Parse `Content-Range: bytes 0-3/<total>` — present when the
            // server honoured the Range request (status 206).
            if let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = cr.lastIndex(of: "/"),
               let total = Int64(cr[cr.index(after: slash)...]) {
                size = total
            } else if size == nil,
                      let len = http.value(forHTTPHeaderField: "Content-Length"),
                      let parsed = Int64(len) {
                size = parsed
            }

            // Some CDNs respond 200 with an HTML error / login page when the
            // request gets misrouted. The first-4-bytes check usually catches
            // it, but surfacing the Content-Type explicitly makes the failure
            // legible to the user.
            if let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               ct.contains("text/html") || ct.contains("application/xhtml") {
                detail = "URL serves an HTML page, not a model file. The link may be a model card or a login redirect — copy the direct download URL instead."
            }

            switch http.statusCode {
            case 200, 206: break    // OK
            case 401, 403:
                detail = "Gated repository — sign in on Hugging Face and use a public mirror, or pick a non-gated model."
            case 404:
                detail = "URL returned 404 (file not found)."
            case 429:
                detail = "Rate-limited (429). Try again in a few minutes."
            default:
                detail = "Server returned status \(http.statusCode)."
            }
        }

        // GGUF magic test — 0x47475546 in big-endian = "GGUF".
        if data.count >= 4 {
            isGGUF = data.prefix(4) == Data([0x47, 0x47, 0x55, 0x46])
        }

        return URLProbe(
            sizeBytes: size,
            isGGUF: isGGUF,
            suggestedName: Self.suggestedName(from: url),
            statusCode: statusCode,
            detail: detail
        )
    }

    /// Derives a friendly model name from a URL's filename:
    /// `Llama-3.2-3B-Instruct-Q4_K_M.gguf` → `Llama 3.2 3B Instruct Q4_K_M`.
    /// Returns nil when the URL has no obvious filename component.
    nonisolated static func suggestedName(from url: URL) -> String? {
        let raw = url.lastPathComponent
        guard !raw.isEmpty, raw != "/" else { return nil }
        var name = raw
        if let dot = name.lastIndex(of: ".") {
            name = String(name[..<dot])
        }
        // Hyphens between words read better as spaces; underscores stay
        // (they're idiomatic in quantisation labels like Q4_K_M).
        name = name.replacingOccurrences(of: "-", with: " ")
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
    }

    func importFromURL(name: String, url: URL, contextLength: Int = 4096, knownSizeBytes: Int64? = nil) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw URLImportError.invalidName
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "mlx" else {
            throw URLImportError.invalidURL
        }

        // Normalise the URL. Two transformations are worth doing here so the
        // typical user-pasted Hugging Face URL just works:
        //
        //   1. `https://huggingface.co/<repo>/blob/<rev>/file.gguf`
        //      → `https://huggingface.co/<repo>/resolve/<rev>/file.gguf`
        //      (the `blob` URL serves an HTML preview page; `resolve` serves
        //      the raw bytes)
        //
        //   2. Reject obvious dead-ends — directory listings, .json sidecars,
        //      `tree/` URLs — early so the user gets a clear error instead of
        //      a 250 KB HTML file failing the GGUF magic check after a
        //      multi-second download.
        let normalisedURL = Self.normaliseModelURL(url)
        try Self.validateModelURL(normalisedURL)

        // Build a stable ID from the name: lowercase, spaces → hyphens, alphanum only.
        let sanitized = trimmedName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        let safeSanitized = sanitized.isEmpty ? "custom" : sanitized
        let modelID = "user-\(safeSanitized)-\(Int(Date().timeIntervalSince1970) % 100_000)"

        let isMLX = url.scheme?.lowercased() == "mlx"

        // Derive family and parameter count from the URL + display name so
        // ModelCapabilityProfile.resolve() picks the right sampling profile
        // and instruction-follower tier. Without this, every custom model
        // resolved to the conservative `default` profile (isWeak=true,
        // lean mode) regardless of actual size — a 7B Mistral got the
        // same osekaný prompt as a 1B Llama.
        let searchText = url.absoluteString + " " + trimmedName
        let detectedFamily = Self.detectFamilyFromText(searchText)
        let detectedParams = Self.detectParamCountFromText(trimmedName)

        let model = LocalModel(
            id: modelID,
            displayName: trimmedName,
            family: detectedFamily,
            parameterCount: detectedParams,
            quantization: "?",
            // Populating sizeBytes from the URL probe lets the disk-space
            // preflight in `start(_:)` actually catch "phone is full"
            // for user-added models. A `nil` falls back to the legacy
            // sentinel (0) which skips the preflight gracefully.
            sizeBytes: knownSizeBytes ?? 0,
            contextLength: contextLength,
            downloadURL: normalisedURL,
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Unknown",
            // The "Add from URL" flow supports both .gguf links and mlx:// repos.
            backend: isMLX ? .mlx : .llamaCpp,
            format: isMLX ? .mlx : .gguf,
            isUserAdded: true
        )

        catalog.addUserModel(model)

        // Start download immediately for both formats — background URLSession
        // handles network interruptions and retries, so the user sees real
        // progress and the load step finds files already on disk.
        if isMLX {
            Task { await startMLXDownload(model) }
        } else {
            start(model)
        }
    }

    /// Detects the model family from a combined URL + display-name string.
    /// Mirrors HFModelMapper.detectFamily so custom `mlx://` models get the
    /// same capability profile as catalog-discovered models of the same family.
    nonisolated static func detectFamilyFromText(_ text: String) -> String {
        let t = text.lowercased()
        if t.contains("llama")                          { return "Llama" }
        if t.contains("gemma-3n") || t.contains("gemma3n") { return "Gemma3n" }
        if t.contains("gemma")                          { return "Gemma" }
        if t.contains("mistral")                        { return "Mistral" }
        if t.contains("qwen")                           { return "Qwen" }
        if t.contains("phi")                            { return "Phi" }
        if t.contains("smollm")                         { return "SmolLM2" }
        return ""
    }

    /// Parses a parameter count string (e.g. "7B", "3.8B") from a display name.
    /// Returns "?" when nothing recognisable is found.
    nonisolated static func detectParamCountFromText(_ name: String) -> String {
        let pattern = #"\b(\d+(?:\.\d+)?)\s*[bBmM]\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range, in: name) else { return "?" }
        return String(name[range]).uppercased()
    }

    /// Rewrites Hugging Face `blob/` URLs to `resolve/` so the download
    /// returns raw bytes instead of an HTML preview. Other URLs pass through
    /// unchanged. Static so `importFromURL` callers (and tests) can use it
    /// without instantiating the service.
    nonisolated static func normaliseModelURL(_ url: URL) -> URL {
        guard url.host?.contains("huggingface.co") == true else { return url }
        let path = url.path
        guard path.contains("/blob/") else { return url }
        let rewritten = path.replacingOccurrences(of: "/blob/", with: "/resolve/")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.path = rewritten
        return comps?.url ?? url
    }

    /// Throws `URLImportError.unsupportedURL` for URLs that obviously can't
    /// produce a GGUF — directory listings, model card pages, sidecar
    /// metadata files. Keeps the user out of the slow-fail loop where a
    /// download succeeds, validation fails, and they have to start over.
    nonisolated static func validateModelURL(_ url: URL) throws {
        if url.scheme?.lowercased() == "mlx" {
            // MLX repo URLs must contain both an org and a repo name —
            // `mlx://mlx-community/Gemma-3n-4B-it-MLX-4bit`. Anything
            // shorter (no host, no path, host with no repo) can't be
            // turned into a Hugging Face repo ID, so reject it now.
            guard let host = url.host, !host.isEmpty else {
                throw URLImportError.unsupportedURL(
                    "MLX URL must include the repository owner — e.g. mlx://mlx-community/Llama-3.2-1B-Instruct-4bit."
                )
            }
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.isEmpty {
                throw URLImportError.unsupportedURL(
                    "MLX URL must include a repository name — e.g. mlx://mlx-community/Llama-3.2-1B-Instruct-4bit."
                )
            }
            return
        }
        
        let path = url.path.lowercased()
        // Hugging Face repo-overview / file-tree pages.
        if path.contains("/tree/") || path.hasSuffix("/main") || path.hasSuffix("/master") {
            throw URLImportError.unsupportedURL(
                "URL points to a Hugging Face directory listing. " +
                "Open the .gguf file on Hugging Face and copy its 'Download' link."
            )
        }
        // Sidecar metadata, archives, or non-GGUF weight formats. We can't
        // run inference on any of these. The unsupported list is broader
        // than what the GGUF magic check rejects — the goal is to fail fast
        // with a clear message before burning bytes.
        let badSuffixes = [
            ".json", ".md", ".txt", ".html", ".htm",
            ".bin", ".safetensors", ".pt", ".onnx",
            ".zip", ".tar", ".gz", ".7z",
            ".py", ".ipynb", ".sh", ".yaml", ".yml"
        ]
        if let suffix = badSuffixes.first(where: { path.hasSuffix($0) }) {
            throw URLImportError.unsupportedURL(
                "Model files must be GGUF — \(suffix) files aren't supported here."
            )
        }
        // A bare repo URL with no file path.
        if url.pathComponents.count <= 3 {
            throw URLImportError.unsupportedURL(
                "URL must point at a specific .gguf file, not a repository."
            )
        }
    }

    enum URLImportError: LocalizedError {
        case invalidName
        case invalidURL
        case unsupportedURL(String)

        var errorDescription: String? {
            switch self {
            case .invalidName:                return "Model name is required."
            case .invalidURL:                 return "URL must start with http:// or https://."
            case .unsupportedURL(let detail): return detail
            }
        }
    }

    /// Re-scans the models directory and reconciles catalog install states.
    /// Safe to call from pull-to-refresh; delegates to ModelCatalogService.
    func reconcileInstallStates() async {
        await catalog.reconcileInstallStates(localModels: localModels)
    }

    /// Finds MLX cache directories on disk whose `org/repo` no longer
    /// matches any catalog entry and removes them. Typical sources of
    /// orphans: user deleted a custom model while its background
    /// download was running, or a curated entry was renamed across an
    /// app version bump. Safe to call repeatedly — a no-op when the
    /// catalog and disk are in sync.
    ///
    /// Logs the reclaimed byte total so users can correlate Settings
    /// "free disk space" growth with this run.
    @discardableResult
    func cleanOrphanedMLXCaches() async -> (count: Int, reclaimedBytes: Int64) {
        let orphans = await catalog.orphanedMLXCacheRepos(localModels: localModels)
        guard !orphans.isEmpty else {
            log.debug("Orphan MLX cache scan: none found")
            return (0, 0)
        }
        var reclaimed: Int64 = 0
        var removed = 0
        for repoId in orphans {
            // Skip caches that belong to an in-flight transport — those
            // are mid-download manifests, not orphans.
            let belongsToActiveModelID = catalog.models.contains { $0.repoId == repoId }
            if belongsToActiveModelID { continue }
            let size = await localModels.mlxCacheSizeBytes(for: repoId)
            do {
                try await localModels.removeMLXCache(for: repoId)
                reclaimed += size
                removed += 1
                log.info("Removed orphan MLX cache '\(repoId, privacy: .public)' (\(size) B)")
            } catch {
                log.error("Failed to remove orphan MLX cache '\(repoId, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("Orphan MLX cache scan: removed \(removed) dir(s) reclaiming \(reclaimed) B")
        return (removed, reclaimed)
    }

    /// Removes MLX cache directories that BELONG to a catalog entry but
    /// have been structurally broken for at least `staleThreshold` seconds.
    ///
    /// **Why both criteria?** `cleanOrphanedMLXCaches` handles the case
    /// where the catalog has no record of a repo (user deleted it, repo
    /// renamed across releases). This handles the dual case: the catalog
    /// still expects the model to be installed, but the on-disk cache is
    /// missing weights / tokenizer / config — typical sources are a
    /// download interrupted by force-quit, a partial restore from iCloud,
    /// or a bit-rot wiping a shard.
    ///
    /// The age gate avoids racing with an in-flight download: a freshly
    /// downloaded cache temporarily looks broken between the manifest
    /// fetch and the moveItem that closes the final shard. We require the
    /// cache to have been broken for ≥ 7 days before yanking it so we
    /// never destroy a download the user is actively waiting on.
    ///
    /// When a cache is removed, the catalog state for that model is
    /// reset to `.notInstalled` so the row in the Models screen flips
    /// from a half-broken "Installed" badge to a "Download" CTA the
    /// user can act on.
    ///
    /// - Parameter staleThreshold: Minimum age (in seconds) of the cache
    ///   directory before broken state qualifies for removal. Default 7
    ///   days. Tests can pass `0` to exercise the cleanup path
    ///   deterministically.
    /// - Returns: Count of removed directories and total reclaimed bytes.
    @discardableResult
    func pruneBrokenMLXCaches(
        staleThreshold: TimeInterval = ModelDownloadService.staleArtefactTTL
    ) async -> (count: Int, reclaimedBytes: Int64) {
        let candidates = catalog.models.filter { model in
            guard model.format == .mlx, model.repoId != nil else { return false }
            // Only look at models the catalog believes are installed.
            // For models in .downloading state we'd be racing with a
            // transport; .notInstalled / .failed have no cache to prune.
            if case .installed = model.installState { return true }
            return false
        }

        guard !candidates.isEmpty else {
            log.debug("Broken MLX cache scan: no installed MLX candidates")
            return (0, 0)
        }

        var reclaimed: Int64 = 0
        var removed = 0

        for model in candidates {
            guard let repoId = model.repoId else { continue }

            // Skip caches with an in-flight transport. The orphan scan
            // already guards this for unknown repos; mirror the check
            // here for known ones.
            if DownloadManager.shared.isActive(model.id) { continue }
            if active[model.id] != nil { continue }

            let inspection = await localModels.inspectMLXCache(for: repoId)
            guard inspection.state != .ready else { continue }  // healthy → leave alone

            // Age gate: don't touch caches that may still be in the
            // tail of a write. `mlxCacheAge` returns nil for missing
            // directories — those are treated as "old enough" because
            // we're about to flip the catalog back to .notInstalled
            // anyway (state and disk are out of sync).
            let age = await localModels.mlxCacheAge(for: repoId)
            if let age, age < staleThreshold {
                log.debug("Broken MLX cache '\(repoId, privacy: .public)' is too young (\(Int(age))s < \(Int(staleThreshold))s) — leaving for next pass")
                continue
            }

            let size = await localModels.mlxCacheSizeBytes(for: repoId)
            do {
                try await localModels.removeMLXCache(for: repoId)
                reclaimed += size
                removed += 1
                let reason = inspection.failureReason ?? "structurally incomplete"
                log.info("Removed broken MLX cache '\(repoId, privacy: .public)' (\(size) B, reason: \(reason, privacy: .public)) and reset catalog state for '\(model.id, privacy: .public)'")
                // Flip catalog so the UI offers Download instead of pretending
                // the model is still installed. Best-effort — if the catalog
                // mutation throws (it shouldn't), we still reclaimed the disk.
                catalog.setInstallState(.notInstalled, for: model.id)
            } catch {
                log.error("Failed to remove broken MLX cache '\(repoId, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }

        log.info("Broken MLX cache scan: removed \(removed) dir(s) reclaiming \(reclaimed) B")
        return (removed, reclaimed)
    }

    /// Composite hygiene pass — runs both orphan and broken-cache cleanup
    /// in one call. Callers in the bootstrap path use this so the
    /// scheduling story stays in one place; tests can still hit either
    /// half independently.
    @discardableResult
    func runMLXCacheHygiene() async -> (orphans: Int, broken: Int, reclaimedBytes: Int64) {
        let orphanResult = await cleanOrphanedMLXCaches()
        let brokenResult = await pruneBrokenMLXCaches()
        return (
            orphans: orphanResult.count,
            broken: brokenResult.count,
            reclaimedBytes: orphanResult.reclaimedBytes + brokenResult.reclaimedBytes
        )
    }

    /// Cancels all active downloads, deletes every `.gguf` file on disk,
    /// and resets every catalog entry to `.notInstalled`.
    func resetAllModels() async {
        for modelID in Array(active.keys) {
            cancel(modelID)
        }
        try? await localModels.removeAll()
        for model in catalog.models {
            catalog.setInstallState(.notInstalled, for: model.id)
        }
    }

    // MARK: - Shared post-download finalization

    /// Shared install step used by both real and simulated paths.
    /// Moves `tempURL` into `localURL`, validates the resulting file,
    /// updates catalog state, and fires `onModelInstalled`.
    private func completeInstall(
        modelID: String,
        tempURL: URL,
        localURL: URL
    ) async {
        // If the download was cancelled between callback and here, swallow the
        // temp file and bail. Callers have already reset catalog state.
        guard active[modelID] != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        active[modelID]?.phase = .installing

        do {
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: tempURL, to: localURL)
        } catch {
            log.error("moveItem failed for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempURL)
            catalog.setInstallState(
                .failed(reason: "File move failed: \(error.localizedDescription)"),
                for: modelID
            )
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }

        // Validate the resulting file before declaring success. Three guards:
        //   1. The destination file actually exists at the path we just
        //      moved into. `moveItem` could (in theory) succeed and a
        //      sandbox quirk leave nothing behind.
        //   2. The file is non-trivial in size. The probe step has a 1 KB
        //      threshold for the temp file; we re-check here on the final
        //      path so a future code-path change can't bypass it.
        //   3. GGUF magic header — catches HTML error pages saved with a
        //      .gguf extension by `URLSession.downloadTask`.
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            log.error("Install finalize failed for '\(modelID, privacy: .public)': destination missing after move at \(localURL.path, privacy: .public)")
            catalog.setInstallState(
                .failed(reason: "Installed file is missing on disk. Try downloading again."),
                for: modelID
            )
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }
        let installedSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? -1
        if installedSize <= 0 {
            log.error("Install finalize failed for '\(modelID, privacy: .public)': zero-byte file at \(localURL.path, privacy: .public)")
            try? FileManager.default.removeItem(at: localURL)
            catalog.setInstallState(
                .failed(reason: "Installed file is empty. The download may have been interrupted — try again."),
                for: modelID
            )
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }
        if !Self.isValidGGUFHeader(at: localURL) {
            log.error("GGUF magic check failed for '\(modelID, privacy: .public)' size=\(installedSize, privacy: .public) at \(localURL.path, privacy: .public)")
            try? FileManager.default.removeItem(at: localURL)
            catalog.setInstallState(
                .failed(reason: "Downloaded file is not a valid GGUF model. The URL may be gated, require authentication, or point to an error page."),
                for: modelID
            )
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }

        // Parse the GGUF header before flipping install state. Two reasons:
        //   1. A file with a valid magic but a truncated metadata section
        //      will fail to load anyway — better to surface the failure
        //      now while the user is on the install spinner than 30 s
        //      later when they tap "Load".
        //   2. Successful parse populates the catalog cache so the next
        //      load() can log template source + effective context without
        //      paying the parse cost on the @MainActor.
        let parsedMeta = GGUFModelMetadata.read(at: localURL)
        if parsedMeta == nil {
            log.error("GGUF metadata parse failed for '\(modelID, privacy: .public)' size=\(installedSize, privacy: .public) at \(localURL.path, privacy: .public)")
            try? FileManager.default.removeItem(at: localURL)
            catalog.setInstallState(
                .failed(reason: "Downloaded file has a valid GGUF magic header but its metadata is unreadable. The file may be partially corrupted — try again."),
                for: modelID
            )
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }

        log.info("Installed '\(modelID, privacy: .public)' size=\(installedSize, privacy: .public) bytes at \(localURL.path, privacy: .public)")
        catalog.setInstallState(.installed(localURL: localURL), for: modelID)
        endDownloadSignpost(modelID, outcome: "success")
        // Read GGUF header now while the file is fresh on disk and the user
        // is already waiting on the install spinner — pushes the parse cost
        // off the first chat send. Non-GGUF formats no-op inside the catalog
        // helper. The parse is O(header), bounded at ~1 MB by the reader.
        catalog.cacheGGUFMetadata(for: modelID, fileURL: localURL)
        active[modelID] = nil
        tasks[modelID] = nil
        log.info("Model '\(modelID, privacy: .public)' installed at \(localURL.path, privacy: .public)")

        // Hook out to AppContainer for auto-activation of the first installed model.
        if let model = catalog.model(withID: modelID) {
            await onModelInstalled?(model)
        }
    }

    /// Reads the first 4 bytes of `url` and checks for the `GGUF` magic.
    /// Returns `false` for missing files, unreadable files, or non-GGUF files.
    static func isValidGGUFHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        return magic == Data([0x47, 0x47, 0x55, 0x46])
    }

    // MARK: - Real download

    enum DownloadError: LocalizedError {
        case checksumMismatch(expected: String, actual: String)
        case fileMoveFailed(String)
        case fileMissingAfterDownload
        case insufficientDiskSpace(required: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .checksumMismatch(let expected, let actual):
                return "SHA-256 mismatch: expected \(expected.prefix(12))…, got \(actual.prefix(12))…"
            case .fileMoveFailed(let msg):
                return "Downloaded file could not be moved into Models directory: \(msg)"
            case .fileMissingAfterDownload:
                return "Model file is missing after download — the system may have deleted the temp file."
            case .insufficientDiskSpace(let required, let available):
                let fmt = ByteCountFormatter()
                fmt.allowedUnits = [.useMB, .useGB]
                fmt.countStyle = .file
                return "Nedostatek místa: potřeba \(fmt.string(fromByteCount: required)), dostupné \(fmt.string(fromByteCount: available))."
            }
        }
    }

    // MARK: - MLX background download

    /// Starts a background multi-file download for an MLX model.
    ///
    /// Unlike GGUF downloads (single URLSessionDownloadTask), MLX repos
    /// contain many files (config, tokenizer, weight shards). This method:
    ///   1. Fetches the file manifest from the HuggingFace API.
    ///   2. Hands every file to `MLXBackgroundDownloader`, which uses a
    ///      dedicated background URLSession — downloads survive screen-off.
    ///   3. On completion the catalog transitions to `.installed` and
    ///      `onModelInstalled` fires for auto-activation.
    func startMLXDownload(_ model: LocalModel) async {
        guard let repoId = model.repoId else {
            log.error("MLX: Cannot download '\(model.id, privacy: .public)' — no repoId")
            catalog.setInstallState(.failed(reason: "Invalid model URL (no HF repo ID)."), for: model.id)
            return
        }
        // Re-entrancy guard: in-flight transport OR an in-memory active
        // entry both mean "this model is already being downloaded".
        // Without this a double-tap on the Download button could enqueue
        // two manifest fetches → two sets of background tasks against
        // the same destination directory.
        guard !DownloadManager.shared.isActive(model.id), active[model.id] == nil else {
            log.notice("MLX: startMLXDownload bailed for '\(model.id, privacy: .public)' — already active")
            return
        }

        // Disk-space preflight
        if model.sizeBytes > 0,
           let free = Self.availableDiskSpaceBytes(),
           free < model.sizeBytes {
            let err = DownloadError.insufficientDiskSpace(required: model.sizeBytes, available: free)
            log.error("MLX: Preflight failed for '\(model.id, privacy: .public)' — \(err.errorDescription ?? "", privacy: .public)")
            catalog.setInstallState(.failed(reason: err.errorDescription ?? "Insufficient disk space"), for: model.id)
            return
        }

        // Auth preflight — fail fast before kicking off the manifest
        // round-trip when the catalog says this repo is gated AND the
        // user hasn't configured a token. The HF API would reject the
        // manifest fetch with HTTP 401 anyway, but doing the check here
        // gives the user a clearer next step ("open Settings → Hugging
        // Face") instead of a generic auth error 200ms later.
        if model.requiresAuth, !HFTokenStore.hasToken {
            let msg = "Tento model je chráněný. Otevři Nastavení → Hugging Face, vlož svůj token, a zkus to znovu."
            log.warning("MLX: Auth preflight failed for '\(model.id, privacy: .public)' — no HF token in Keychain")
            catalog.setInstallState(.failed(reason: msg), for: model.id)
            return
        }

        // Track preparing state in `active` so the UI shows the same
        // unified phase machine for MLX as it does for GGUF.
        active[model.id] = DownloadState(
            modelID: model.id,
            progress: 0,
            isCancelled: false,
            phase: .preparing
        )
        catalog.setInstallState(.downloading(progress: 0), for: model.id)
        log.info("MLX: Fetching file manifest for '\(repoId, privacy: .public)'")

        do {
            // Fetch full manifest (files + SHA) so we can both filter
            // for inference assets AND record the upstream commit hash
            // for later "model has updates available" detection. Falls
            // back gracefully if the API omits SHA (rare; old repos).
            let manifest = try await HuggingFaceAPIClient.fetchModelManifest(repoId: repoId)
            let files = manifest.files
            if let sha = manifest.sha {
                log.info("MLX: Pinning '\(model.id, privacy: .public)' to upstream commit \(sha.prefix(8), privacy: .public)")
                pendingRepoSHAs[model.id] = sha
            }
            // Open the signpost interval AFTER the manifest fetch — we
            // want the bar in Instruments to start at "transport
            // begins" so the manifest round-trip doesn't inflate
            // per-download timings.
            beginDownloadSignpost(model.id)
            guard !files.isEmpty else {
                log.error("MLX: Manifest returned no inference files for '\(repoId, privacy: .public)'")
                catalog.setInstallState(
                    .failed(reason: "No inference files found in this repository. The repo may not contain MLX-compatible weights."),
                    for: model.id
                )
                active[model.id] = nil
                return
            }
            // Sum file sizes from the manifest so user-added MLX models
            // (where `sizeBytes == 0`) still get a disk-space preflight.
            // Only checked when at least one file reports a size — HF
            // omits sizes for unresolved LFS pointers.
            let manifestTotal = files.compactMap(\.size).reduce(Int64(0), +)
            if manifestTotal > 0,
               let free = Self.availableDiskSpaceBytes(),
               free < manifestTotal {
                let err = DownloadError.insufficientDiskSpace(required: manifestTotal, available: free)
                log.error("MLX: Manifest-based disk preflight failed for '\(model.id, privacy: .public)' — \(err.errorDescription ?? "", privacy: .public)")
                catalog.setInstallState(.failed(reason: err.errorDescription ?? "Insufficient disk space"), for: model.id)
                active[model.id] = nil
                return
            }
            let cacheDir = await localModels.resolvedMLXCacheURL(for: repoId)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            DownloadManager.shared.startMLX(modelID: model.id, repoId: repoId, cacheDir: cacheDir, files: files)
            // Pin the manifest's total expected size so the completion-side
            // validator can compare against the on-disk total. Only stored
            // when at least one file in the manifest reported a size —
            // otherwise we have nothing to compare against and the
            // structural-inspection check has to suffice.
            if manifestTotal > 0 {
                pendingManifestTotals[model.id] = manifestTotal
            }
            // Move into the .downloading phase so the UI flips from the
            // brief "Preparing…" spinner to a real progress bar as soon
            // as the first byte lands.
            active[model.id]?.phase = .downloading
            log.info("MLX: Started background download of \(files.count) files for '\(model.id, privacy: .public)' totalBytes=\(manifestTotal)")
        } catch let hfErr as HFError {
            // Typed HF errors get user-actionable, localized reasons. The
            // gated-repo case used to surface as a cryptic "HF API returned
            // HTTP 401" — now the user sees "vyžaduje přihlášení nebo
            // přijetí licence" and (eventually) a CTA to open HF.
            log.error("MLX: Manifest fetch failed for '\(repoId, privacy: .public)' (typed): \(String(describing: hfErr), privacy: .public)")
            let reason: String = {
                switch hfErr {
                case .gatedRepository(let id, _):
                    return "Tento model je chráněný (\(id)) — musíš se přihlásit na huggingface.co a přijmout licenci. Pro provoz čistě v offline appce vyber jiný (otevřený) MLX model."
                case .notFound(let id):
                    return "Repozitář \(id) na Hugging Face neexistuje. Zkontroluj přesný název nebo vyber jiný model."
                }
            }()
            catalog.setInstallState(.failed(reason: reason), for: model.id)
            active[model.id] = nil
        } catch {
            log.error("MLX: Manifest fetch failed for '\(repoId, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            catalog.setInstallState(.failed(reason: "Could not fetch model file list: \(error.localizedDescription)"), for: model.id)
            active[model.id] = nil
        }
    }

    // MARK: - Coordinator callbacks

    private func setupCoordinatorCallbacks() {
        DownloadManager.shared.wireAndReconnect(
            ggufProgress: { [weak self] id, fraction in
                guard let self else { return }
                self.active[id]?.progress = fraction
                self.active[id]?.phase = .downloading
                self.catalog.setInstallState(.downloading(progress: fraction), for: id)
            },
            ggufCompleted: { [weak self] id, tempURL in
                DownloadManager.shared.markFinished(modelID: id)
                guard let self else { return }
                Task { await self.finalizeDownload(modelID: id, tempURL: tempURL) }
            },
            ggufFailed: { [weak self] id, error, resumeData in
                DownloadManager.shared.markFinished(modelID: id)
                guard let self else { return }
                self.handleDownloadError(modelID: id, error: error, resumeData: resumeData)
            },
            mlxProgress: { [weak self] id, fraction in
                guard let self else { return }
                // Once the first byte lands the row should leave the
                // "Preparing…" indeterminate state. Without this the
                // phase stays at `.preparing` until installation.
                if self.active[id] != nil {
                    self.active[id]?.progress = fraction
                    self.active[id]?.phase = .downloading
                }
                self.catalog.setInstallState(.downloading(progress: fraction), for: id)
            },
            mlxCompleted: { [weak self] id in
                DownloadManager.shared.markFinished(modelID: id)
                guard let self else { return }
                guard let model = self.catalog.model(withID: id),
                      let repoId = model.repoId else { return }
                // Validate the cache directory before declaring success.
                // The MLX background downloader is permissive: it counts a
                // job as complete once every URLSession task it enqueued
                // finishes, but if the manifest filter dropped a critical
                // file (or HF served a 200-with-error for one of them)
                // the directory can end up structurally incomplete. We
                // re-inspect with the same helper the runtime pre-flight
                // uses so both surfaces report identical failures.
                self.active[id]?.phase = .validating
                self.log.info("MLX: Validating cache for '\(id, privacy: .public)'")
                Task {
                    let cacheDir = await self.localModels.resolvedMLXCacheURL(for: repoId)
                    let inspection = await self.localModels.inspectMLXCache(for: repoId)
                    // The inspect call hops to the LocalModelService actor;
                    // during that suspension the user may have tapped
                    // Cancel or Delete on the row, which cleared `active`
                    // and reset the catalog state. Bail out so we don't
                    // resurrect a cancelled install.
                    guard self.active[id] != nil,
                          self.catalog.model(withID: id) != nil else {
                        self.log.notice("MLX: completion validation skipped for '\(id, privacy: .public)' — no longer active")
                        return
                    }
                    guard inspection.state == .ready else {
                        let reason = inspection.failureReason ?? "Model directory is incomplete."
                        self.log.error("MLX: Post-download validation failed for '\(id, privacy: .public)' — \(reason, privacy: .public) missing=\(inspection.missingItems.joined(separator: ","), privacy: .public)")
                        // Wipe the partial cache so the next Retry starts
                        // from a clean slate rather than re-resolving on
                        // top of a known-broken directory.
                        try? await self.localModels.removeMLXCache(for: repoId)
                        self.catalog.setInstallState(.failed(reason: reason), for: id)
                        self.active[id] = nil
                        self.pendingManifestTotals.removeValue(forKey: id)
                        return
                    }

                    // Size-vs-manifest verification. Structural inspection
                    // (.ready) confirms config + tokenizer + ≥ 1 MB of
                    // safetensors weight, but it can't tell a complete
                    // download from one where a shard finished short
                    // without raising a transport error. Compare the
                    // on-disk total against the manifest's sum-of-sizes
                    // with a 1 % tolerance (covers small attribute /
                    // alignment differences) and refuse anything smaller.
                    if let expected = self.pendingManifestTotals[id], expected > 0 {
                        let actual = await self.localModels.mlxCacheSizeBytes(for: repoId)
                        let tolerance = max(Int64(65_536), expected / 100)  // 1 % or 64 KB floor
                        if actual + tolerance < expected {
                            let reason = "Download appears truncated: got \(actual) B, expected ~\(expected) B from the manifest."
                            self.log.error("MLX: Size validation failed for '\(id, privacy: .public)' — actual=\(actual) expected=\(expected) tolerance=\(tolerance)")
                            try? await self.localModels.removeMLXCache(for: repoId)
                            self.catalog.setInstallState(.failed(reason: reason), for: id)
                            self.active[id] = nil
                            self.pendingManifestTotals.removeValue(forKey: id)
                            return
                        }
                        self.log.info("MLX: Size validation OK for '\(id, privacy: .public)' (actual=\(actual) B, expected=\(expected) B)")
                    }
                    self.pendingManifestTotals.removeValue(forKey: id)
                    self.active[id]?.phase = .installing
                    self.catalog.setInstallState(.installed(localURL: cacheDir), for: id)
                    // Pin the upstream SHA captured at manifest-fetch
                    // time. Clearing the sidecar entry keeps the map
                    // bounded across many install/uninstall cycles.
                    if let pinnedSHA = self.pendingRepoSHAs.removeValue(forKey: id) {
                        self.catalog.setInstalledRepoSHA(pinnedSHA, for: id)
                    }
                    self.endDownloadSignpost(id, outcome: "success")
                    self.log.info("MLX: Model '\(id, privacy: .public)' installed at \(cacheDir.path, privacy: .public) totalWeights=\(inspection.totalWeightsBytes)")
                    self.active[id] = nil
                    if let model = self.catalog.model(withID: id) {
                        await self.onModelInstalled?(model)
                    }
                }
            },
            mlxFailed: { [weak self] id, error in
                DownloadManager.shared.markFinished(modelID: id)
                guard let self else { return }
                self.pendingRepoSHAs.removeValue(forKey: id)
                self.pendingManifestTotals.removeValue(forKey: id)
                self.endDownloadSignpost(id, outcome: "failed")
                let reason = error.localizedDescription
                self.log.error("MLX: Download failed for '\(id, privacy: .public)': \(reason, privacy: .public)")
                self.catalog.setInstallState(.failed(reason: reason), for: id)
                self.active[id] = nil
            }
        )
    }

    private func realDownload(model: LocalModel) async {
        let modelID = model.id
        let localURL = await localModels.localURL(for: modelID)

        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            log.error("createDirectory failed for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }

        active[modelID]?.phase = .downloading

        if let resumeData = loadResumeData(for: modelID) {
            // Clear resume data now; a fresh cancel will store new resume data.
            clearResumeData(for: modelID)
            DownloadManager.shared.resume(modelID: modelID, resumeData: resumeData)
        } else {
            DownloadManager.shared.start(modelID: modelID, url: model.downloadURL)
        }
        // Download now runs independently in the background session.
    }

    @MainActor
    private func finalizeDownload(modelID: String, tempURL: URL) async {
        // Guard: if the download was cancelled between completion callback and here,
        // just clean up the temp file and do nothing.
        guard active[modelID] != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            log.error("Temp file missing after download for '\(modelID, privacy: .public)'")
            catalog.setInstallState(
                .failed(reason: DownloadError.fileMissingAfterDownload.errorDescription
                        ?? "Soubor modelu chybí po stažení."),
                for: modelID
            )
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }

        // File-size sanity check: a real GGUF is measured in megabytes; a file
        // under 1 KB is almost certainly an HTML error page saved by URLSession
        // (gated-model auth challenge body, CDN error page, etc.). The HTTP
        // status guard in BackgroundDownloadCoordinator catches most non-2xx
        // cases, but some CDNs reply 200 with an HTML body regardless.
        let fileSizeThreshold: Int64 = 1_024  // 1 KB
        let fileAttrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path)
        if let fileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value,
           fileSize < fileSizeThreshold {
            log.error("Downloaded file suspiciously small (\(fileSize, privacy: .public) B) for '\(modelID, privacy: .public)' — likely an error page")
            try? FileManager.default.removeItem(at: tempURL)
            catalog.setInstallState(
                .failed(reason: "Downloaded file is too small (\(fileSize) bytes). The URL may be gated or return an error page instead of a model."),
                for: modelID
            )
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }

        let localURL = await localModels.localURL(for: modelID)
        let model = catalog.models.first { $0.id == modelID }

        // Optional SHA-256 check — only runs when the curated catalog provides
        // a hash. User-added models never have one.
        if let expectedHash = model?.sha256 {
            active[modelID]?.phase = .validating
            catalog.setInstallState(.downloading(progress: 1.0), for: modelID)
            do {
                let hashURL = tempURL  // lokální kopie pro capture
                let actualHash = try await Task.detached(priority: .userInitiated) {
                    try await ModelDownloadService.sha256Hash(of: hashURL)
                }.value
                guard actualHash.lowercased() == expectedHash.lowercased() else {
                    let err = DownloadError.checksumMismatch(expected: expectedHash, actual: actualHash)
                    log.error("SHA-256 mismatch for '\(modelID, privacy: .public)'")
                    try? FileManager.default.removeItem(at: tempURL)
                    catalog.setInstallState(.failed(reason: err.errorDescription ?? "Checksum mismatch"), for: modelID)
                    active[modelID] = nil
                    tasks[modelID] = nil
                    return
                }
            } catch {
                log.error("SHA-256 hashing failed for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: tempURL)
                catalog.setInstallState(.failed(reason: error.localizedDescription), for: modelID)
                active[modelID] = nil
                tasks[modelID] = nil
                return
            }
        }

        catalog.setInstallState(.downloading(progress: 1.0), for: modelID)
        await completeInstall(modelID: modelID, tempURL: tempURL, localURL: localURL)
    }

    @MainActor
    private func handleDownloadError(modelID: String, error: Error, resumeData: Data?) {
        if let data = resumeData {
            saveResumeData(data, for: modelID)
        }
        let reason: String
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                reason = resumeData != nil
                    ? "Download paused — no network. Tap Retry to resume when connected."
                    : "No internet connection. Try again when connected."
            case .cancelled:
                // User-initiated cancel; state already reset by cancel().
                active[modelID] = nil
                tasks[modelID] = nil
                return
            default:
                reason = "Network error: \(urlError.localizedDescription)"
            }
        } else {
            reason = error.localizedDescription
        }
        log.error("Download failed for '\(modelID, privacy: .public)': \(reason, privacy: .public)")
        catalog.setInstallState(.failed(reason: reason), for: modelID)
        active[modelID] = nil
        tasks[modelID] = nil
    }

    // MARK: - Resume Data

    private func loadResumeData(for modelID: String) -> Data? {
        UserDefaults.standard.data(forKey: resumeDataKey(for: modelID))
    }

    private func saveResumeData(_ data: Data, for modelID: String) {
        UserDefaults.standard.set(data, forKey: resumeDataKey(for: modelID))
        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: resumeTimestampKey(for: modelID)
        )
    }

    func clearResumeData(for modelID: String) {
        UserDefaults.standard.removeObject(forKey: resumeDataKey(for: modelID))
        UserDefaults.standard.removeObject(forKey: resumeTimestampKey(for: modelID))
    }

    private func resumeDataKey(for modelID: String) -> String {
        "com.homehub.app.resumeData.\(modelID)"
    }

    private func resumeTimestampKey(for modelID: String) -> String {
        "com.homehub.app.resumeTimestamp.\(modelID)"
    }

    /// Drops resume blobs that are either older than `maxAge` or attached
    /// to a model the catalog no longer knows about. Without this, a
    /// failed download can leave a multi-megabyte resume blob in
    /// UserDefaults forever — and on subsequent app launches the "Paused"
    /// badge keeps appearing on a model the server has long since
    /// renamed or removed.
    ///
    /// Called from `AppContainer.bootstrap()` after the catalog has been
    /// reconciled against disk. Safe to call repeatedly; idempotent.
    ///
    /// - Parameter maxAge: How long a resume blob is considered fresh.
    ///   Default 7 days — long enough that a user who started a download
    ///   on the train can finish it the next morning, short enough that
    ///   stale blobs from old test runs don't accumulate.
    func pruneStaleResumeData(maxAge: TimeInterval = ModelDownloadService.staleArtefactTTL) {
        let prefix = "com.homehub.app.resumeData."
        let timestampPrefix = "com.homehub.app.resumeTimestamp."
        let knownIDs = Set(catalog.models.map(\.id))
        let cutoff = Date().timeIntervalSince1970 - maxAge

        var droppedCount = 0
        for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix(prefix) {
            let modelID = String(key.dropFirst(prefix.count))
            let timestampKey = "\(timestampPrefix)\(modelID)"
            let timestamp = UserDefaults.standard.double(forKey: timestampKey)

            // Drop when:
            //   * the model isn't in the catalog any more (deleted or renamed), OR
            //   * we have a timestamp and it's older than the cutoff, OR
            //   * we don't have a timestamp at all (legacy blobs from before
            //     this commit — they predate observability so we can't tell
            //     how stale they are; safer to drop).
            let modelGone = !knownIDs.contains(modelID)
            let stale = timestamp == 0 || timestamp < cutoff

            if modelGone || stale {
                UserDefaults.standard.removeObject(forKey: key)
                UserDefaults.standard.removeObject(forKey: timestampKey)
                droppedCount += 1
            }
        }

        if droppedCount > 0 {
            log.info("Pruned \(droppedCount, privacy: .public) stale resume-data blob(s) from UserDefaults.")
        }
    }

    static func sha256Hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1_024 * 1_024
        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
