import Foundation

/// Single-row result from a document embedding call.
struct DocumentEmbeddingResult: Sendable, Equatable {
    let chunkID: UUID
    let vector: [Float]
}

/// Narrow protocol that the ingest pipeline depends on. Decoupled
/// from `EmbeddingService` so:
/// - tests can substitute a deterministic stub without standing up
///   the full NLContextualEmbedding model
/// - a future remote embedding backend (or a different on-device
///   model) can be plugged in without touching `IngestPipeline`
protocol DocumentEmbedder: Sendable {
    /// Embeds an array of texts. The returned array length must
    /// equal `chunkIDs.count`. Implementations that fail on a single
    /// item should still return the rest with that slot's vector
    /// being a zero-length array — the pipeline treats those as
    /// indexing failures and surfaces them on the document record.
    func embed(
        texts: [String],
        chunkIDs: [UUID]
    ) async -> [DocumentEmbeddingResult]

    /// Stable identifier for the embedding model used. Persisted on
    /// `DocumentRecord` so a later model swap can detect outdated
    /// indices and queue them for reindexing.
    var modelID: String { get }

    /// Stable version tag for the embedding *configuration* (model +
    /// pooling strategy + tokeniser hint). Bumped when any of those
    /// change in a way that invalidates existing vectors.
    var version: String { get }
}

/// Adapter from `EmbeddingService` (the actor used by Memory and
/// Conversation services) to `DocumentEmbedder`. Reuses the shared
/// instance so we get a single embedding-model load and a single
/// LRU cache across all consumers.
struct EmbeddingServiceDocumentEmbedder: DocumentEmbedder {
    let embedder: EmbeddingService
    let modelID: String
    let version: String

    init(
        embedder: EmbeddingService,
        modelID: String = KBVersions.embedding,
        version: String = KBVersions.embedding
    ) {
        self.embedder = embedder
        self.modelID = modelID
        self.version = version
    }

    func embed(
        texts: [String],
        chunkIDs: [UUID]
    ) async -> [DocumentEmbeddingResult] {
        precondition(texts.count == chunkIDs.count)
        var out: [DocumentEmbeddingResult] = []
        out.reserveCapacity(texts.count)
        for (text, id) in zip(texts, chunkIDs) {
            let vec = await embedder.embeddingVector(for: text) ?? []
            out.append(DocumentEmbeddingResult(chunkID: id, vector: vec))
        }
        return out
    }
}
