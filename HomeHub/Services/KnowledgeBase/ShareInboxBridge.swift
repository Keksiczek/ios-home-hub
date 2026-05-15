import Foundation

/// Drains `ShareRequest`s queued by the Share Extension and converts
/// them into `IngestJob`s for the Knowledge Base pipeline.
///
/// ## Design boundary
/// The Share Extension intentionally knows **nothing** about
/// `IngestJob` / chunks / vectors / embeddings. Its only output is
/// `(SharePayload, ShareRequest)` written to JSON files in the App
/// Group. This bridge is the seam where that minimal contract turns
/// into the host app's richer ingest model — same pattern as a
/// classic outbox → ingest worker.
///
/// ## What we do per request
/// 1. Resolve the matching `SharePayload`.
/// 2. Map the requested `action` to an `IngestAction`.
/// 3. Enqueue an `IngestJob` (URLs/text become inline-text jobs;
///    files reference the App Group inbox path the extension wrote).
/// 4. Flip the request status to `.consumedByApp`.
///
/// Failures don't propagate up — we mark the offending request
/// `.failed` and keep going so one malformed payload can't block
/// the whole queue.
struct ShareInboxBridge {

    let payloadStore: SharePayloadStore
    let jobStore: IngestJobStore
    let storage: SharedStorage

    /// Drains every pending request. Returns the number of requests
    /// that were converted into ingest jobs (i.e. flipped to
    /// `.consumedByApp`). Failures count as 0.
    @discardableResult
    func drain() async -> Int {
        var converted = 0
        let pending: [ShareRequest]
        do {
            pending = try await payloadStore.pendingRequests()
        } catch {
            HHLog.kb.error(
                "share inbox: failed to load pending: \(error.localizedDescription, privacy: .public)"
            )
            return 0
        }

        for request in pending {
            do {
                guard let payload = try await payloadStore.payload(id: request.payloadID) else {
                    try await payloadStore.updateRequest(
                        id: request.id,
                        status: .failed,
                        errorMessage: "Payload nenalezen."
                    )
                    continue
                }
                let job = try await makeIngestJob(payload: payload, request: request)
                try await jobStore.upsert(job)
                try await payloadStore.updateRequest(
                    id: request.id,
                    status: .consumedByApp
                )
                converted += 1
            } catch {
                HHLog.kb.error(
                    "share inbox: convert failed: \(error.localizedDescription, privacy: .public)"
                )
                try? await payloadStore.updateRequest(
                    id: request.id,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
            }
        }
        return converted
    }

    // MARK: - Mapping

    private func makeIngestJob(
        payload: SharePayload,
        request: ShareRequest
    ) async throws -> IngestJob {
        let action: IngestAction
        switch request.action {
        case ShareAction.saveToKnowledgeBase: action = .saveToKnowledgeBase
        case ShareAction.askInHomeHub:        action = .askOverDocument
        default:                              action = .saveToKnowledgeBase
        }

        switch payload.kind {
        case .pdf, .file:
            // File payloads already live in the App Group inbox.
            // We resolve through `SharedStorage.absoluteURL(for:)`
            // here only to validate the path is still inside the
            // container — defends against a malformed payload file
            // produced by an older extension version.
            guard let relPath = payload.localPayloadRelativePath else {
                throw makeError("Payload je označen jako soubor, ale nemá lokální cestu.")
            }
            _ = try storage.absoluteURL(forRelativePath: relPath)
            return IngestJob(
                id: UUID(),
                createdAt: payload.createdAt,
                updatedAt: .now,
                sourceType: .shareExtension,
                workspaceID: request.workspaceID,
                action: action,
                status: .queued,
                title: payload.title,
                sourceAppBundleID: payload.sourceAppBundleID,
                originalURL: payload.originalURL,
                localPayloadRelativePath: relPath,
                mimeType: payload.mimeType,
                contentHash: payload.contentHash,
                errorMessage: nil,
                documentID: nil
            )

        case .text:
            // Inline text shares: materialise the payload as a
            // `.txt` file inside `kb/files/` so the existing
            // pipeline (which expects a file path) doesn't need a
            // special case for inline strings. The stored file
            // becomes the canonical source for chunking.
            let text = payload.text ?? ""
            let dest = storage.filesURL.appendingPathComponent(
                "\(payload.id.uuidString).txt"
            )
            try Data(text.utf8).write(to: dest, options: .atomic)
            let relPath = storage.relativePath(for: dest) ?? dest.path
            return IngestJob(
                id: UUID(),
                createdAt: payload.createdAt,
                updatedAt: .now,
                sourceType: .shareExtension,
                workspaceID: request.workspaceID,
                action: action,
                status: .queued,
                title: payload.title,
                sourceAppBundleID: payload.sourceAppBundleID,
                originalURL: payload.originalURL,
                localPayloadRelativePath: relPath,
                mimeType: "text/plain",
                contentHash: payload.contentHash,
                errorMessage: nil,
                documentID: nil
            )

        case .url:
            // URL shares run through `WebContentExtractor` — a fetch
            // pass + HTML→text extraction. Failure paths (404, gated
            // content, JS-only SPA, non-HTML content-type) propagate
            // as typed errors so the request is marked `.failed` with
            // a real reason instead of producing a placeholder doc.
            guard let url = payload.originalURL else {
                throw makeError("URL share neobsahuje URL.")
            }
            HHLog.kb.info("ingest: URL share start for \(url.absoluteString, privacy: .public)")
            let page: WebContentExtractor.Page
            do {
                page = try await WebContentExtractor.fetch(url)
            } catch {
                HHLog.kb.error("ingest: URL extract failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
            let title = page.title ?? payload.title ?? url.absoluteString
            // Header lines preserve provenance — the source URL, the
            // page title, and the fetched-bytes count — so downstream
            // retrieval can quote them and the user can audit the
            // record's origin in the document detail sheet.
            let body = """
            Source URL: \(page.finalURL.absoluteString)
            Title: \(title)
            Fetched bytes: \(page.fetchedBytes)

            \(page.plainText)
            """
            HHLog.kb.info("ingest: URL extract ok for \(page.finalURL.absoluteString, privacy: .public) chars=\(page.plainText.count, privacy: .public)")
            let dest = storage.filesURL.appendingPathComponent(
                "\(payload.id.uuidString).url.txt"
            )
            try Data(body.utf8).write(to: dest, options: .atomic)
            let relPath = storage.relativePath(for: dest) ?? dest.path
            return IngestJob(
                id: UUID(),
                createdAt: payload.createdAt,
                updatedAt: .now,
                sourceType: .webPage,
                workspaceID: request.workspaceID,
                action: action,
                status: .queued,
                title: title,
                sourceAppBundleID: payload.sourceAppBundleID,
                originalURL: page.finalURL,
                localPayloadRelativePath: relPath,
                mimeType: "text/plain",
                contentHash: payload.contentHash,
                errorMessage: nil,
                documentID: nil
            )
        }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(
            domain: "ShareInboxBridge",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
