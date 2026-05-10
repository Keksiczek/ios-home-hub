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
                let job = try makeIngestJob(payload: payload, request: request)
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
    ) throws -> IngestJob {
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
            // URLs become a single-line `.txt` "URL: <…>" record.
            // Real reader-mode HTML extraction is out of scope for
            // Epic 2 — keep the pipeline working for URLs and let
            // a future task replace the inline materialisation
            // with an HTML→text reader pass.
            guard let url = payload.originalURL else {
                throw makeError("URL share neobsahuje URL.")
            }
            let body = "URL: \(url.absoluteString)\n\nTitle: \(payload.title ?? "")"
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
                title: payload.title ?? url.absoluteString,
                sourceAppBundleID: payload.sourceAppBundleID,
                originalURL: url,
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
