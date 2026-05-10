import Foundation
import UniformTypeIdentifiers
import CryptoKit

/// Pulls `NSItemProvider` attachments into our `SharePayload` model.
///
/// One extractor per extension invocation. The extension's
/// `viewDidAppear` hands the controller's `extensionContext` over,
/// the extractor walks every `inputItems → attachments`, classifies
/// each via UTType, copies file payloads into the App Group inbox,
/// and synthesises a `SharePayload` record.
///
/// ## Why not SLComposeServiceViewController + `loadItem(forTypeIdentifier:)`?
/// SLComposeServiceViewController bundles a UIKit composer UI we
/// don't want — we want an immediate save with a tiny status, not a
/// caption field. This class talks to `NSItemProvider` directly, which
/// is what SLComposeServiceViewController does under the hood anyway.
///
/// ## Why CryptoKit hashing here, not in `SharedStorage`?
/// `SharedStorage.sha256(of:)` exists for files and `Data`, but the
/// extractor mixes inline strings (URLs, text) with files; a small
/// helper inside this type keeps the hash strategy local — change
/// to CRC32 / xxHash later without touching the host app's API.
struct ShareItemExtractor {

    let storage: SharedStorage
    let payloadStore: SharePayloadStore
    let hostBundleID: String?

    /// Default action recorded on every `ShareRequest`. The simple
    /// extension UI doesn't yet expose action-picker chips; leave
    /// this configurable so a richer UI later can pass through
    /// `saveToKnowledgeBase` / `askInHomeHub` without changing the
    /// extractor.
    let defaultAction: String

    /// Hard cap to defend against the user trying to share a
    /// 4 GB video by accident. Refuse and report; the host app
    /// would otherwise OOM during ingest. 64 MB matches the
    /// `IngestPipeline.maxIngestableBytes` limit so the contracts
    /// align across the boundary.
    static let maxBytes: Int64 = 64 * 1024 * 1024

    /// Extracts every shareable attachment from the given context
    /// and returns the count of *successfully* persisted payloads.
    /// Errors on individual attachments are logged and recorded on
    /// the request — they don't abort the rest of the batch.
    func extract(
        from inputItems: [NSExtensionItem]
    ) async -> ExtractionSummary {
        var summary = ExtractionSummary()
        for item in inputItems {
            guard let providers = item.attachments else { continue }
            for provider in providers {
                do {
                    if let result = try await extractOne(provider: provider, item: item) {
                        try await payloadStore.appendPayload(result.payload)
                        let request = ShareRequest(
                            payloadID: result.payload.id,
                            action: defaultAction,
                            status: .stored
                        )
                        try await payloadStore.appendRequest(request)
                        summary.succeeded += 1
                        SharedKitLog.shareExtension.notice(
                            "stored share payload kind=\(result.payload.kind.rawValue, privacy: .public) id=\(result.payload.id, privacy: .public)"
                        )
                    } else {
                        summary.skipped += 1
                    }
                } catch {
                    summary.failed += 1
                    SharedKitLog.shareExtension.error(
                        "extract failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        return summary
    }

    struct ExtractionSummary: Sendable {
        var succeeded: Int = 0
        var failed: Int = 0
        var skipped: Int = 0

        var didStoreAnything: Bool { succeeded > 0 }
        var totalAttachments: Int { succeeded + failed + skipped }
    }

    // MARK: - Per-attachment classifier

    private struct ExtractedItem {
        let payload: SharePayload
    }

    private func extractOne(
        provider: NSItemProvider,
        item: NSExtensionItem
    ) async throws -> ExtractedItem? {
        // Order matters: try the most specific UTType first so a
        // PDF doesn't fall through into the generic "file" branch
        // (which would skip text extraction and give us less useful
        // metadata).
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            return try await loadPDF(provider: provider, item: item)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return try await loadURL(provider: provider, item: item)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return try await loadText(provider: provider, item: item)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await loadFile(provider: provider, item: item)
        }
        // Nothing we recognise — return nil so the caller bumps
        // `skipped` instead of `failed`. Some apps attach
        // proprietary types we don't care about (e.g. private
        // pasteboard tokens); silent skip is the right move.
        return nil
    }

    // MARK: URL

    private func loadURL(
        provider: NSItemProvider,
        item: NSExtensionItem
    ) async throws -> ExtractedItem? {
        guard let url = try await provider.loadURLAsync() else { return nil }
        // File URLs masquerade as URLs in the share sheet (e.g.
        // sharing a document from Files); route those into the file
        // path so we copy + hash properly.
        if url.isFileURL {
            return try await loadFileURL(url, provider: provider, item: item)
        }
        let title = item.attributedContentText?.string
            ?? provider.suggestedName
        let bytes = Data(url.absoluteString.utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let payload = SharePayload(
            sourceAppBundleID: hostBundleID,
            kind: .url,
            title: title,
            text: nil,
            originalURL: url,
            localPayloadRelativePath: nil,
            mimeType: "text/uri-list",
            fileSize: nil,
            contentHash: hash
        )
        return ExtractedItem(payload: payload)
    }

    // MARK: Text

    private func loadText(
        provider: NSItemProvider,
        item: NSExtensionItem
    ) async throws -> ExtractedItem? {
        guard let text = try await provider.loadStringAsync() else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bytes = Data(trimmed.utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let title = String(trimmed.prefix(80))
        let payload = SharePayload(
            sourceAppBundleID: hostBundleID,
            kind: .text,
            title: title,
            text: trimmed,
            originalURL: nil,
            localPayloadRelativePath: nil,
            mimeType: "text/plain",
            fileSize: Int64(bytes.count),
            contentHash: hash
        )
        return ExtractedItem(payload: payload)
    }

    // MARK: PDF

    private func loadPDF(
        provider: NSItemProvider,
        item: NSExtensionItem
    ) async throws -> ExtractedItem? {
        let url = try await provider.loadFileRepresentationAsync(
            forTypeIdentifier: UTType.pdf.identifier
        )
        return try copyAndRecord(
            from: url,
            kind: .pdf,
            mimeType: "application/pdf",
            provider: provider
        )
    }

    // MARK: Generic file

    private func loadFile(
        provider: NSItemProvider,
        item: NSExtensionItem
    ) async throws -> ExtractedItem? {
        let url = try await provider.loadFileRepresentationAsync(
            forTypeIdentifier: UTType.fileURL.identifier
        )
        return try await loadFileURL(url, provider: provider, item: item)
    }

    private func loadFileURL(
        _ url: URL,
        provider: NSItemProvider,
        item: NSExtensionItem
    ) async throws -> ExtractedItem? {
        let utType = UTType(filenameExtension: url.pathExtension)
        let mime = utType?.preferredMIMEType ?? "application/octet-stream"
        let kind: SharePayloadKind = utType?.conforms(to: .pdf) == true ? .pdf : .file
        return try copyAndRecord(
            from: url,
            kind: kind,
            mimeType: mime,
            provider: provider
        )
    }

    // MARK: - File copy + hash

    private func copyAndRecord(
        from sourceURL: URL,
        kind: SharePayloadKind,
        mimeType: String,
        provider: NSItemProvider
    ) throws -> ExtractedItem? {
        let fm = FileManager.default
        // Apple's documentation: the URL returned by
        // `loadFileRepresentation` lives in a *temporary* sandbox
        // and may be deleted as soon as the closure returns. Copy
        // it into the App Group inbox NOW.
        let attrs = try fm.attributesOfItem(atPath: sourceURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= Self.maxBytes else {
            SharedKitLog.shareExtension.error(
                "refusing share: size=\(size, privacy: .public) > cap=\(Self.maxBytes, privacy: .public)"
            )
            throw NSError(
                domain: "ShareItemExtractor",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Soubor je prázdný nebo přesahuje 64 MB."]
            )
        }

        let safeName = sourceURL.lastPathComponent
        let targetName = "\(UUID().uuidString)-\(safeName)"
        let destURL = storage.inboxURL.appendingPathComponent(targetName)
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        try fm.copyItem(at: sourceURL, to: destURL)

        let hash = try SharedStorage.sha256(of: destURL)
        guard let relPath = storage.relativePath(for: destURL) else {
            try? fm.removeItem(at: destURL)
            throw NSError(
                domain: "ShareItemExtractor",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Cesta uniká z App Group containeru."]
            )
        }
        let title = provider.suggestedName ?? sourceURL.deletingPathExtension().lastPathComponent
        let payload = SharePayload(
            sourceAppBundleID: hostBundleID,
            kind: kind,
            title: title,
            text: nil,
            originalURL: sourceURL,
            localPayloadRelativePath: relPath,
            mimeType: mimeType,
            fileSize: size,
            contentHash: hash
        )
        return ExtractedItem(payload: payload)
    }
}

// MARK: - NSItemProvider async helpers
//
// `NSItemProvider.loadItem(forTypeIdentifier:options:completionHandler:)`
// is callback-based; bridge it once here so the extractor stays in
// `async/await` style.

private extension NSItemProvider {
    /// Generic `loadItem` returns `NSSecureCoding`, which isn't
    /// `Sendable` — Swift 6 strict concurrency rejects passing it
    /// out of the continuation closure. Specialise per-type so the
    /// continuation only ever resumes with a known-Sendable value
    /// (URL, String, NSURL bridged to URL).
    func loadURLAsync() async throws -> URL? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL?, Error>) in
            self.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: item as? URL)
                }
            }
        }
    }

    func loadStringAsync() async throws -> String? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            self.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let s = item as? String {
                    cont.resume(returning: s)
                } else if let url = item as? URL,
                          let s = try? String(contentsOf: url, encoding: .utf8) {
                    // Some apps pass plain text as an attachment URL
                    // pointing to a temp .txt file. Keep parity with
                    // SLComposeServiceViewController by reading it.
                    cont.resume(returning: s)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Returns a usable `URL` for the file representation. The temp
    /// URL passed into the completion is valid only for the duration
    /// of the synchronous closure — we copy out before returning.
    /// (Internally we wrap `loadFileRepresentation`, which does the
    /// security-scoped dance for us.)
    func loadFileRepresentationAsync(forTypeIdentifier typeIdentifier: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            // The OS deletes the URL right after the completion
            // handler returns, so copy into a temp location we own
            // first; `ShareItemExtractor.copyAndRecord` will then
            // copy out of THAT into the App Group inbox.
            //
            // Two-step copy is intentional: it keeps the inbox
            // write inside the actor-isolated extractor (which is
            // where the size cap + hash live) without making the
            // OS-provided closure responsible for the heavy lifting.
            self.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { tempURL, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let tempURL else {
                    cont.resume(throwing: NSError(
                        domain: "NSItemProvider",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "OS nevrátil cestu k souboru."]
                    ))
                    return
                }
                do {
                    let stagingDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("HomeHubShareStage", isDirectory: true)
                    try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                    let staged = stagingDir.appendingPathComponent(
                        "\(UUID().uuidString)-\(tempURL.lastPathComponent)"
                    )
                    try FileManager.default.copyItem(at: tempURL, to: staged)
                    cont.resume(returning: staged)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
