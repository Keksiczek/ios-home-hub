import Foundation

// MARK: - Payload

/// Kind of content carried by a single share. Drives both the
/// Share Extension's normaliser and the host app's UI badge.
enum SharePayloadKind: String, Codable, Sendable, Hashable {
    case url
    case text
    case pdf
    case file
}

/// Normalised representation of one item dropped through the iOS
/// share sheet. Lives entirely on disk (in `kb/index/share-payloads.json`
/// + canonical files under `inbox/`) so the host app can pick it up
/// after the extension's lifetime ends.
///
/// Identifier is `id` (UUID) — `contentHash` is a separate dedupe key
/// so re-sharing the same article twice produces two records with
/// the same hash, and the host app's pipeline can decide whether
/// to merge or keep them as distinct events.
struct SharePayload: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let createdAt: Date
    let sourceAppBundleID: String?

    let kind: SharePayloadKind
    let title: String?
    /// Inline text payload for `kind == .text` (or extracted snippet
    /// from `.url` shares where the source app provided one).
    let text: String?
    /// Original URL when the user shared a link from Safari /
    /// browser. `nil` for raw text/file shares.
    let originalURL: URL?
    /// Path **relative** to the App Group container root. Use
    /// `SharedStorage.absoluteURL(forRelativePath:)` to resolve.
    /// `nil` for `kind == .text` and (sometimes) `.url`.
    let localPayloadRelativePath: String?
    let mimeType: String?
    let fileSize: Int64?
    /// SHA-256 over the canonicalised payload (the file contents
    /// for files, the UTF-8 bytes of text/URL for inline payloads).
    /// Used for dedupe and as the tie to `IngestJob.contentHash`
    /// when the host app converts this into an ingest job.
    let contentHash: String

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        sourceAppBundleID: String? = nil,
        kind: SharePayloadKind,
        title: String? = nil,
        text: String? = nil,
        originalURL: URL? = nil,
        localPayloadRelativePath: String? = nil,
        mimeType: String? = nil,
        fileSize: Int64? = nil,
        contentHash: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceAppBundleID = sourceAppBundleID
        self.kind = kind
        self.title = title
        self.text = text
        self.originalURL = originalURL
        self.localPayloadRelativePath = localPayloadRelativePath
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.contentHash = contentHash
    }
}

// MARK: - Share request

enum ShareRequestStatus: String, Codable, Sendable, Hashable {
    case queued
    case stored
    case failed
    case consumedByApp
}

/// What the user wants the host app to do with the shared payload.
/// Free-form string instead of an enum so the Share Extension and
/// the host app can evolve action names without versioning the
/// shared model file. Recognised today:
/// - `"saveToInbox"` (default)
/// - `"saveToKnowledgeBase"` (queue an ingest job)
/// - `"askInHomeHub"` (open chat with payload as draft)
enum ShareAction {
    static let saveToInbox = "saveToInbox"
    static let saveToKnowledgeBase = "saveToKnowledgeBase"
    static let askInHomeHub = "askInHomeHub"
}

/// Persistent unit of work created by the Share Extension and
/// drained by the host app. The host app converts it into an
/// `IngestJob` (or surfaces it in the inbox, depending on `action`)
/// and flips the status to `.consumedByApp`.
struct ShareRequest: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date

    let payloadID: UUID
    let workspaceID: String?
    let action: String
    var status: ShareRequestStatus
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date = .now,
        payloadID: UUID,
        workspaceID: String? = nil,
        action: String = ShareAction.saveToInbox,
        status: ShareRequestStatus = .queued,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payloadID = payloadID
        self.workspaceID = workspaceID
        self.action = action
        self.status = status
        self.errorMessage = errorMessage
    }
}

// MARK: - Store

/// JSON-on-disk persistence for `SharePayload` + `ShareRequest`.
/// Lives in the App Group container so the Share Extension and the
/// host app can both read/write the same files.
///
/// ## Concurrency
/// Two layers of safety, because two different threats:
/// 1. **In-process**: `actor` isolation serialises writes from the
///    host app's many SwiftUI/Task callers.
/// 2. **Cross-process**: the Share Extension is a *separate process*.
///    `actor` doesn't help across processes, and a plain
///    `Data.write(.atomic)` only guarantees a single write completes
///    or fails — two writers can still race "read-old → modify →
///    write-new" and lose one of the appends. `NSFileCoordinator`
///    serialises file IO across processes for everyone using the
///    same coordinator-aware path, which is exactly the case here
///    (extension and host app both go through this store).
actor SharePayloadStore {

    private let storage: SharedStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let payloadsFile = "share-payloads.json"
    private static let requestsFile = "share-requests.json"

    init(storage: SharedStorage) {
        self.storage = storage
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: Payloads

    func loadPayloads() throws -> [SharePayload] {
        try readArray(SharePayload.self, file: Self.payloadsFile)
    }

    func payload(id: UUID) throws -> SharePayload? {
        try loadPayloads().first(where: { $0.id == id })
    }

    func appendPayload(_ payload: SharePayload) throws {
        var all = try loadPayloads()
        // Idempotent on UUID — re-running the same extension instance
        // (rare, but the system can replay) won't double up.
        if let idx = all.firstIndex(where: { $0.id == payload.id }) {
            all[idx] = payload
        } else {
            all.append(payload)
        }
        try writeArray(all, file: Self.payloadsFile)
    }

    func deletePayload(id: UUID) throws {
        var all = try loadPayloads()
        all.removeAll { $0.id == id }
        try writeArray(all, file: Self.payloadsFile)
    }

    // MARK: Requests

    func loadRequests() throws -> [ShareRequest] {
        try readArray(ShareRequest.self, file: Self.requestsFile)
    }

    func appendRequest(_ request: ShareRequest) throws {
        var all = try loadRequests()
        if let idx = all.firstIndex(where: { $0.id == request.id }) {
            all[idx] = request
        } else {
            all.append(request)
        }
        try writeArray(all, file: Self.requestsFile)
    }

    func updateRequest(
        id: UUID,
        status: ShareRequestStatus,
        errorMessage: String? = nil
    ) throws {
        var all = try loadRequests()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        all[idx].status = status
        all[idx].updatedAt = .now
        all[idx].errorMessage = errorMessage
        try writeArray(all, file: Self.requestsFile)
    }

    func deleteRequest(id: UUID) throws {
        var all = try loadRequests()
        all.removeAll { $0.id == id }
        try writeArray(all, file: Self.requestsFile)
    }

    /// Pending requests = anything that's not yet `.consumedByApp`.
    /// Order: oldest first, so the user's intent (share-then-share-
    /// then-share) is processed in the order they shared.
    func pendingRequests() throws -> [ShareRequest] {
        try loadRequests()
            .filter { $0.status != .consumedByApp }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Generic IO

    private func readArray<T: Decodable>(_ type: T.Type, file: String) throws -> [T] {
        let url = storage.indexURL.appendingPathComponent(file)
        return try Self.coordinatedRead(at: url) { data -> [T] in
            guard let data else { return [] }
            return try decoder.decode([T].self, from: data)
        }
    }

    private func writeArray<T: Encodable>(_ values: [T], file: String) throws {
        let url = storage.indexURL.appendingPathComponent(file)
        let data = try encoder.encode(values)
        try Self.coordinatedWrite(data: data, to: url)
    }

    // MARK: - NSFileCoordinator helpers
    //
    // Bracket every read/write with a coordinator block on the same
    // URL so the Share Extension and the host app serialise their
    // accesses across the App Group container. Without this, a
    // simultaneous "extension appends a payload" and "host app
    // marks a request consumed" can lose one of the writes (both
    // read the same starting state, both write back their mutated
    // copy, last writer wins).
    //
    // Each helper hops to a synchronous critical section; we're
    // already inside the actor so the additional serialisation is
    // cheap and only matters when another *process* is actively
    // touching the same file.

    private static func coordinatedRead<T>(
        at url: URL,
        decode: (Data?) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<T, Error> = .failure(
            NSError(domain: "SharePayloadStore", code: -10,
                    userInfo: [NSLocalizedDescriptionKey: "coordinator did not run"])
        )
        coordinator.coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordinatorError
        ) { actualURL in
            do {
                if FileManager.default.fileExists(atPath: actualURL.path) {
                    let data = try Data(contentsOf: actualURL)
                    result = .success(try decode(data))
                } else {
                    result = .success(try decode(nil))
                }
            } catch {
                result = .failure(error)
            }
        }
        if let coordinatorError {
            throw coordinatorError
        }
        return try result.get()
    }

    private static func coordinatedWrite(data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var writeError: Error?
        coordinator.coordinate(
            writingItemAt: url,
            // `.forReplacing` tells the coordinator we're swapping
            // the entire file contents — the right hint for a JSON
            // array we re-serialise wholesale on every mutation.
            options: .forReplacing,
            error: &coordinatorError
        ) { actualURL in
            do {
                try data.write(to: actualURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }
}
