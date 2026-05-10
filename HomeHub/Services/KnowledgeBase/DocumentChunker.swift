import Foundation

/// Deterministic, character-based chunker. Same input → same
/// chunks, every time, on every device. That's a hard requirement:
/// reindexing a document under a new embedding model must produce
/// the same chunk boundaries so existing chunk IDs (and any UI that
/// references them — citations, highlight ranges) stay stable.
///
/// Why character-based, not token-based:
/// - The on-device embedding (NLContextualEmbedding) tokenises
///   internally by language and we don't see the tokeniser's
///   boundaries. Computing exact tokens up front would mean loading
///   the embedding model just to chunk, which would block ingest on
///   cold start.
/// - Chunk size is approximate anyway — what matters is that no
///   chunk is so big the embedding model truncates it silently. A
///   1000-char window comfortably stays under the 512-token limit
///   typical for sentence-level embeddings.
enum DocumentChunker {
    /// Defaults sized so:
    /// - chunkSize fits well under typical embedding token limits
    /// - overlap preserves enough context that a query landing on a
    ///   chunk boundary still hits a relevant neighbour
    static let defaultChunkSize = 1000
    static let defaultOverlap = 200

    /// Returns the list of chunks for a document. The chunker does
    /// NOT trim or normalise input beyond collapsing pure-whitespace
    /// gaps — keeping the original text means `startOffset`/
    /// `endOffset` are valid indices into the source string for
    /// citations.
    static func chunks(
        for text: String,
        documentID: UUID,
        chunkSize: Int = defaultChunkSize,
        overlap: Int = defaultOverlap
    ) -> [ChunkRecord] {
        precondition(chunkSize > 0)
        precondition(overlap >= 0 && overlap < chunkSize)

        // Operate over a UTF8 view by character count for a
        // reasonable proxy of "amount of text". Using `.utf16.count`
        // would skew on multibyte scripts; `Array(text)` keeps it
        // grapheme-aware which is what users see.
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }

        var out: [ChunkRecord] = []
        var start = 0
        var ordinal = 0
        let stride = max(1, chunkSize - overlap)

        while start < chars.count {
            let end = min(start + chunkSize, chars.count)
            let slice = String(chars[start..<end])

            // Hash the (text, ordinal) pair so the chunk ID is
            // deterministic across reindexes. Same document → same
            // chunk IDs → citations and highlights stay valid.
            let chunkID = Self.deterministicID(
                documentID: documentID,
                ordinal: ordinal,
                text: slice
            )

            let chunk = ChunkRecord(
                id: chunkID,
                documentID: documentID,
                ordinal: ordinal,
                text: slice,
                tokenEstimate: TokenEstimator.tokens(in: slice),
                pageNumber: nil,
                sectionPath: nil,
                startOffset: start,
                endOffset: end,
                embeddingVectorRef: String(ordinal)
            )
            out.append(chunk)

            if end == chars.count { break }
            start += stride
            ordinal += 1
        }
        return out
    }

    /// Per-page chunker. Chunks live within a single page (no
    /// cross-page chunks), which means citations always point to a
    /// single page number — and the ingest pipeline never has to
    /// hold the entire document in one string.
    ///
    /// Trade-off: chunks are page-bounded, so a slide deck with
    /// short slides yields short chunks. That's an acceptable
    /// compromise — embedding quality on a 200-char chunk is still
    /// good for retrieval, and we get crisper citation locations
    /// in exchange.
    ///
    /// `startOffset`/`endOffset` are page-local (indices into the
    /// page's text), which is what citation overlays usually want.
    static func chunks(
        forPages pages: [DocumentReaderService.PageText],
        documentID: UUID,
        chunkSize: Int = defaultChunkSize,
        overlap: Int = defaultOverlap
    ) -> [ChunkRecord] {
        precondition(chunkSize > 0)
        precondition(overlap >= 0 && overlap < chunkSize)

        var out: [ChunkRecord] = []
        var globalOrdinal = 0
        let stride = max(1, chunkSize - overlap)

        for page in pages {
            let chars = Array(page.text)
            guard !chars.isEmpty else { continue }

            var start = 0
            while start < chars.count {
                let end = min(start + chunkSize, chars.count)
                let slice = String(chars[start..<end])

                // Same deterministic-ID strategy as the legacy
                // single-string overload — folding `globalOrdinal`
                // (not the page-local offset) into the hash so a
                // page-by-page rechunk produces the same UUIDs as
                // the equivalent single-string chunking sequence.
                let chunkID = Self.deterministicID(
                    documentID: documentID,
                    ordinal: globalOrdinal,
                    text: slice
                )
                let chunk = ChunkRecord(
                    id: chunkID,
                    documentID: documentID,
                    ordinal: globalOrdinal,
                    text: slice,
                    tokenEstimate: TokenEstimator.tokens(in: slice),
                    pageNumber: page.pageNumber,
                    sectionPath: nil,
                    startOffset: start,
                    endOffset: end,
                    embeddingVectorRef: String(globalOrdinal)
                )
                out.append(chunk)
                globalOrdinal += 1
                if end == chars.count { break }
                start += stride
            }
        }
        return out
    }

    /// Stable UUID derived from the document ID + ordinal + chunk
    /// text. Collision-resistant enough for practical purposes
    /// (we're not adversarial-defending here, just making reindex
    /// idempotent).
    private static func deterministicID(
        documentID: UUID,
        ordinal: Int,
        text: String
    ) -> UUID {
        var bytes = [UInt8]()
        withUnsafeBytes(of: documentID.uuid) { bytes.append(contentsOf: $0) }
        var ord = UInt64(ordinal).littleEndian
        withUnsafeBytes(of: &ord) { bytes.append(contentsOf: $0) }
        // Folding the chunk text into the hash means a re-chunk with
        // a different chunkSize produces different IDs (which is what
        // we want — those are different chunks).
        bytes.append(contentsOf: Array(text.utf8))
        let hash = SharedStorage.sha256(of: Data(bytes))
        // Take the first 32 hex chars (16 bytes) as the UUID payload.
        let prefix = String(hash.prefix(32))
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            let start = prefix.index(prefix.startIndex, offsetBy: i * 2)
            let end = prefix.index(start, offsetBy: 2)
            uuidBytes[i] = UInt8(prefix[start..<end], radix: 16) ?? 0
        }
        let uuidTuple: uuid_t = (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        )
        return UUID(uuid: uuidTuple)
    }
}
