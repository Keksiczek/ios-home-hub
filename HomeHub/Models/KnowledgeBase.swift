import Foundation

// MARK: - Source / status enums

enum DocumentSourceType: String, Codable, Sendable, Hashable {
    case shareExtension
    case inAppImport
    case webPage
    case other
}

/// Where the document is in the indexing state machine. Persisted on
/// `DocumentRecord` so a crash / process termination can resume from
/// the last reached step rather than redoing the whole ingest.
enum DocumentIndexingStatus: String, Codable, Sendable, Hashable {
    case notIndexed
    case queued
    case parsing
    case chunking
    case embedding
    case indexing
    case indexed
    case failed
}

enum IngestAction: String, Codable, Sendable, Hashable {
    case saveToKnowledgeBase
    case summarizeOnly
    case askOverDocument
}

enum IngestStatus: String, Codable, Sendable, Hashable {
    case queued
    case awaitingApp
    case processing
    case indexed
    case failed
}

// MARK: - Document

/// A persistent record of a single document tracked by the Knowledge
/// Base. The actual file lives at `localFileURL` inside the App Group
/// container; this record holds metadata + the indexing state.
struct DocumentRecord: Identifiable, Codable, Sendable, Equatable, Hashable {
    let id: UUID
    var workspaceID: String?
    var title: String
    let sourceType: DocumentSourceType
    let sourceURL: URL?
    /// Absolute URL inside the App Group container. Persisted as a
    /// relative path under the container in `relativeFilePath` so the
    /// record survives container path changes (the container URL has
    /// device/installation-specific UUIDs).
    var relativeFilePath: String
    let sha256: String
    let fileSize: Int64
    let mimeType: String
    let createdAt: Date

    var indexingStatus: DocumentIndexingStatus
    /// Number of chunks produced for this document. Used to size the
    /// vector file and as a quick "is this fully indexed?" check.
    var chunkCount: Int
    /// Dimension of the embedding vectors. Stored on the document so a
    /// reader can validate the binary vector file without having to
    /// re-load the embedding model.
    var embeddingDimension: Int?

    var parserVersion: String
    var chunkingVersion: String
    var embeddingModelID: String?
    var embeddingVersion: String?
    var lastIndexedAt: Date?
    var errorMessage: String?
}

// MARK: - Chunk

/// One indexed slice of a document. Vectors are NOT stored inline —
/// `embeddingVectorRef` points to the ordinal within the document's
/// binary vector file (`vectors-<docID>.bin`). Keeping the JSON small
/// matters because retrieval reads chunks for every candidate document
/// and a 700-dim Double vector per chunk would balloon disk + load
/// time without any benefit (we always need the vectors via the binary
/// file, not from JSON).
struct ChunkRecord: Identifiable, Codable, Sendable, Equatable, Hashable {
    let id: UUID
    let documentID: UUID
    let ordinal: Int

    let text: String
    let tokenEstimate: Int
    let pageNumber: Int?
    let sectionPath: String?
    let startOffset: Int?
    let endOffset: Int?

    /// Reference into the document's binary vector file. Stored as
    /// `String` (not `Int`) because a future revision may shard
    /// vectors across multiple files (`"<fileTag>:<ordinal>"`); v1
    /// uses the bare ordinal as a string.
    let embeddingVectorRef: String?
}

// MARK: - Ingest job

/// A unit of work for the ingest pipeline. Created either by the
/// Share Extension (writing into the App Group inbox) or by the host
/// app's import flow, then drained by `IngestPipeline`.
struct IngestJob: Identifiable, Codable, Sendable, Equatable, Hashable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date

    let sourceType: DocumentSourceType
    let workspaceID: String?
    let action: IngestAction

    var status: IngestStatus

    var title: String?
    let sourceAppBundleID: String?

    let originalURL: URL?
    /// Relative path under the App Group container. The pipeline
    /// resolves it through `SharedStorage.absoluteURL(forRelativePath:)`.
    let localPayloadRelativePath: String?
    let mimeType: String?

    let contentHash: String
    var errorMessage: String?
    /// Set when the pipeline has matched/created a document for this
    /// job. Lets a restart pick up an in-progress ingest without
    /// re-deduping by hash.
    var documentID: UUID?
}

// MARK: - Retrieval

/// Query passed to `KnowledgeBaseRetrieval`. `documentIDs` and
/// `workspaceID` are AND-combined when both are set.
struct RetrievalQuery: Sendable {
    let workspaceID: String?
    let documentIDs: [UUID]?
    let maxChunks: Int
    let minRelevance: Float
    let queryText: String

    init(
        queryText: String,
        workspaceID: String? = nil,
        documentIDs: [UUID]? = nil,
        maxChunks: Int = 6,
        minRelevance: Float = 0.25
    ) {
        self.queryText = queryText
        self.workspaceID = workspaceID
        self.documentIDs = documentIDs
        self.maxChunks = maxChunks
        self.minRelevance = minRelevance
    }
}

struct RetrievedChunk: Sendable, Equatable {
    let document: DocumentRecord
    let chunk: ChunkRecord
    let similarity: Float
}

protocol KnowledgeBaseRetrieving: Sendable {
    func retrieve(for query: RetrievalQuery) async throws -> [RetrievedChunk]
}

// MARK: - Versioning constants

/// Stable identifier for the current parser. Stored on each
/// `DocumentRecord` so a future parser change can detect docs that
/// were indexed with the old parser and queue a reindex.
enum KBVersions {
    static let parser = "v1"
    static let chunking = "v1.chars-1000-overlap-200"
    static let embedding = "nlcontextual-latin-v1"
}
