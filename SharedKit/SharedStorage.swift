import Foundation
import CryptoKit

/// Thin wrapper over the App Group shared container. Every component
/// that needs a path inside the group asks `SharedStorage` for it
/// instead of calling `FileManager.containerURL(forSecurityApplication
/// GroupIdentifier:)` directly — that way the layout (`inbox/`, `kb/`,
/// etc.) lives in one place and the Share Extension and the host app
/// can't drift on directory names.
///
/// Sendable because everything it returns is a value type and all
/// mutating operations go through `FileManager`, which is documented
/// thread-safe.
struct SharedStorage: Sendable {

    /// App Group identifier used by the host app, the widget, and
    /// (eventually) the Share Extension. Keep in sync with the value
    /// in both entitlements files and `project.yml`.
    static let appGroupIdentifier = "group.cz.keksiczek.homehub.shared"

    enum SharedStorageError: Error, LocalizedError {
        case containerUnavailable
        case relativePathOutsideContainer

        var errorDescription: String? {
            switch self {
            case .containerUnavailable:
                return "App Group container není k dispozici. Zkontrolujte entitlements."
            case .relativePathOutsideContainer:
                return "Cesta uniká z App Group containeru."
            }
        }
    }

    let containerURL: URL

    /// Fails if the entitlement is missing or the system can't return
    /// the container — both are configuration errors that should be
    /// fixed at build time, not retried at runtime.
    init() throws {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw SharedStorageError.containerUnavailable
        }
        self.containerURL = url
        try Self.ensureLayout(under: url)
    }

    // MARK: - Layout

    /// Inbox for files dropped by the Share Extension. The pipeline
    /// owns deletion — the extension is fire-and-forget.
    var inboxURL: URL { containerURL.appendingPathComponent("inbox", isDirectory: true) }

    /// Root for everything Knowledge-Base related: persisted records,
    /// canonical file copies, vector blobs, ingest job queue.
    var knowledgeBaseURL: URL { containerURL.appendingPathComponent("kb", isDirectory: true) }

    /// Canonical storage for ingested files. The pipeline copies the
    /// inbox payload here on first ingest so the Share Extension can
    /// safely delete its temporary file and so the file URL is
    /// stable across the document's lifetime.
    var filesURL: URL { knowledgeBaseURL.appendingPathComponent("files", isDirectory: true) }

    /// JSON + binary index files (documents.json, chunks-*.json,
    /// vectors-*.bin, jobs.json).
    var indexURL: URL { knowledgeBaseURL.appendingPathComponent("index", isDirectory: true) }

    private static func ensureLayout(under root: URL) throws {
        let fm = FileManager.default
        for sub in ["inbox", "kb", "kb/files", "kb/index"] {
            let url = root.appendingPathComponent(sub, isDirectory: true)
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - Relative path resolution

    /// Resolves a relative path back to an absolute URL inside the
    /// container. Defends against `../` traversal so a malformed
    /// `IngestJob` from the inbox can't trick the host app into
    /// reading from outside the App Group.
    func absoluteURL(forRelativePath relativePath: String) throws -> URL {
        let url = containerURL.appendingPathComponent(relativePath)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let containerResolved = containerURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(containerResolved.path) else {
            throw SharedStorageError.relativePathOutsideContainer
        }
        return url
    }

    /// Inverse: turn an absolute URL inside the container into a
    /// stable relative path that can be persisted in `DocumentRecord`
    /// or `IngestJob` without baking in the container's
    /// installation-specific UUID.
    func relativePath(for absoluteURL: URL) -> String? {
        let abs = absoluteURL.standardizedFileURL.path
        let root = containerURL.standardizedFileURL.path
        guard abs.hasPrefix(root) else { return nil }
        var trimmed = String(abs.dropFirst(root.count))
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        return trimmed
    }

    // MARK: - Hashing helpers

    /// Streams the file in 1 MB chunks so a 200 MB PDF doesn't load
    /// fully into memory before hashing.
    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Inbox enumeration

    /// Returns the relative paths of every file currently in the
    /// inbox, deepest-first sorted is irrelevant — callers just need
    /// the list to drain into `IngestJob`s.
    func inboxFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: inboxURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            let isFile = (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile ?? false
            if isFile { out.append(url) }
        }
        return out
    }
}
