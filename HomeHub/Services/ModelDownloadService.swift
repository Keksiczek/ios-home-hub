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

    /// Called on the main actor after a model successfully transitions to
    /// `.installed`. `AppContainer` wires this up to auto-activate the first
    /// installed model when the user hasn't picked one yet — otherwise a
    /// fresh download could never flip `runtime.activeModel != nil` without
    /// the user finding and tapping "Load" manually.
    var onModelInstalled: ((LocalModel) async -> Void)?

    private let localModels: LocalModelService
    private let catalog: ModelCatalogService
    private var tasks: [String: Task<Void, Never>] = [:]

    private let log = Logger(subsystem: "com.homehub.app", category: "ModelDownloadService")

    init(localModels: LocalModelService, catalog: ModelCatalogService) {
        self.localModels = localModels
        self.catalog = catalog
        setupCoordinatorCallbacks()
    }

    func isDownloading(_ modelID: String) -> Bool {
        active[modelID] != nil
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
        // Cancel the URLSession task; coordinator will attempt to save resume data
        // asynchronously. We intentionally do NOT clear resume data here so the
        // user can resume. Call clearResumeData() only when starting fresh.
        BackgroundDownloadCoordinator.shared.cancelDownload(modelID: modelID)
        catalog.setInstallState(.notInstalled, for: modelID)
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

        // Remove file from disk.
        do {
            try await localModels.remove(modelID)
        } catch {
            log.error("Failed to remove model file for '\(modelID, privacy: .public)': \(error.localizedDescription, privacy: .public)")
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
              scheme == "http" || scheme == "https" else {
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

        let model = LocalModel(
            id: modelID,
            displayName: trimmedName,
            family: "Custom",
            parameterCount: "?",
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
            isUserAdded: true
        )

        catalog.addUserModel(model)
        start(model)
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
        let path = url.path.lowercased()
        // Hugging Face repo-overview / file-tree pages.
        if path.contains("/tree/") || path.hasSuffix("/main") || path.hasSuffix("/master") {
            throw URLImportError.unsupportedURL(
                "URL points to a Hugging Face directory listing. " +
                "Open the .gguf file on Hugging Face and copy its 'Download' link."
            )
        }
        // Sidecar metadata. We can't run inference on a .json or a tokenizer.
        let badSuffixes = [".json", ".md", ".txt", ".html", ".bin", ".safetensors"]
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

        // Validate the resulting file is a plausible GGUF before declaring success.
        // This catches e.g. HuggingFace gated-model HTML error pages being saved
        // with a .gguf extension by `URLSession.downloadTask`.
        if !Self.isValidGGUFHeader(at: localURL) {
            log.error("GGUF magic check failed for '\(modelID, privacy: .public)' at \(localURL.path, privacy: .public)")
            try? FileManager.default.removeItem(at: localURL)
            catalog.setInstallState(
                .failed(reason: "Downloaded file is not a valid GGUF model. The URL may be gated, require authentication, or point to an error page."),
                for: modelID
            )
            active[modelID] = nil
            tasks[modelID] = nil
            return
        }

        catalog.setInstallState(.installed(localURL: localURL), for: modelID)
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

    private func setupCoordinatorCallbacks() {
        let coordinator = BackgroundDownloadCoordinator.shared
        coordinator.onProgress = { [weak self] id, fraction in
            guard let self else { return }
            self.active[id]?.progress = fraction
            self.active[id]?.phase = .downloading
            self.catalog.setInstallState(.downloading(progress: fraction), for: id)
        }
        coordinator.onCompleted = { [weak self] id, tempURL in
            guard let self else { return }
            Task { await self.finalizeDownload(modelID: id, tempURL: tempURL) }
        }
        coordinator.onFailed = { [weak self] id, error, resumeData in
            guard let self else { return }
            self.handleDownloadError(modelID: id, error: error, resumeData: resumeData)
        }
        // Now that callbacks are wired, reconnect to any in-flight background
        // session from a previous app run so queued events are delivered here
        // (rather than being dropped before we were ready to handle them).
        coordinator.reconnect()
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

        let coordinator = BackgroundDownloadCoordinator.shared
        if let resumeData = loadResumeData(for: modelID) {
            // Clear resume data now; a fresh cancel will store new resume data.
            clearResumeData(for: modelID)
            coordinator.startDownload(modelID: modelID, resumeData: resumeData)
        } else {
            coordinator.startDownload(modelID: modelID, url: model.downloadURL)
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
            catalog.setInstallState(.failed(reason: DownloadError.fileMissingAfterDownload.errorDescription!), for: modelID)
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
    func pruneStaleResumeData(maxAge: TimeInterval = 7 * 24 * 60 * 60) {
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
