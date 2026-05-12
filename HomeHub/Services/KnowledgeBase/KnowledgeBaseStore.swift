import Foundation

/// Persistence facade for the document Knowledge Base. Mirrors the
/// `Store`/`FileStore` style used elsewhere in the app:
/// JSON-on-disk, single actor, atomic writes. Lives inside the App
/// Group container (`kb/index/`) so a future Share Extension can
/// queue ingest jobs and the host app sees them without IPC.
///
/// ## On-disk layout
/// ```
/// <container>/kb/index/
///   ├─ documents.json       — [DocumentRecord]
///   ├─ chunks-<docID>.json  — [ChunkRecord], one file per document
///   └─ vectors-<docID>.bin  — Float32 vectors, one file per document
/// ```
/// Why per-document files for chunks/vectors:
/// - chunk files stay small (cheap to load on retrieval)
/// - delete-document is a single `removeItem` — no rewrite of a
///   global blob
/// - a corrupted vector file only loses one document, not the whole
///   knowledge base
actor KnowledgeBaseStore {

    private let storage: SharedStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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

    // MARK: - Documents

    func loadDocuments() throws -> [DocumentRecord] {
        try readArray(DocumentRecord.self, from: "documents.json")
    }

    func upsert(document: DocumentRecord) throws {
        var all = try loadDocuments()
        if let idx = all.firstIndex(where: { $0.id == document.id }) {
            all[idx] = document
        } else {
            all.append(document)
        }
        try writeArray(all, to: "documents.json")
    }

    func deleteDocument(id: UUID) throws {
        var all = try loadDocuments()
        all.removeAll { $0.id == id }
        try writeArray(all, to: "documents.json")
        try removeIfExists("chunks-\(id.uuidString).json")
        try removeIfExists("vectors-\(id.uuidString).bin")
    }

    func document(forSHA256 hash: String) throws -> DocumentRecord? {
        try loadDocuments().first { $0.sha256 == hash }
    }

    // MARK: - Chunks

    func loadChunks(documentID: UUID) throws -> [ChunkRecord] {
        try readArray(ChunkRecord.self, from: "chunks-\(documentID.uuidString).json")
    }

    func saveChunks(_ chunks: [ChunkRecord], documentID: UUID) throws {
        try writeArray(chunks, to: "chunks-\(documentID.uuidString).json")
    }

    // MARK: - Vectors (binary blob)
    //
    // File format:
    //   header (16 bytes):
    //     magic    : "HHKB" (4 bytes)
    //     version  : UInt32 little-endian (currently 1)
    //     count    : UInt32 little-endian (number of vectors)
    //     dim      : UInt32 little-endian (vector dimension)
    //   payload:
    //     count * dim * Float32 (little-endian)
    //
    // Float32 instead of Double halves disk + memory cost; the
    // averaged NLContextualEmbedding output is fine at single
    // precision for cosine similarity.

    private static let vectorMagic: [UInt8] = [0x48, 0x48, 0x4B, 0x42] // "HHKB"
    private static let vectorVersion: UInt32 = 1

    func saveVectors(_ vectors: [[Float]], documentID: UUID) throws {
        guard let dim = vectors.first?.count else {
            try removeIfExists("vectors-\(documentID.uuidString).bin")
            return
        }
        // Sanity: every vector has the same dimension. A mismatch
        // means an upstream bug, not user data — fail loud.
        for v in vectors where v.count != dim {
            throw NSError(
                domain: "KnowledgeBaseStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Vector dimension mismatch"]
            )
        }

        var data = Data()
        data.reserveCapacity(16 + vectors.count * dim * MemoryLayout<Float>.size)
        data.append(contentsOf: Self.vectorMagic)
        appendUInt32(Self.vectorVersion, to: &data)
        appendUInt32(UInt32(vectors.count), to: &data)
        appendUInt32(UInt32(dim), to: &data)
        for v in vectors {
            v.withUnsafeBufferPointer { buf in
                data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
            }
        }
        let url = storage.indexURL.appendingPathComponent("vectors-\(documentID.uuidString).bin")
        try data.write(to: url, options: .atomic)
    }

    /// Loads the full vector matrix for a document. Returns `nil` if
    /// the file is missing or the header doesn't validate (e.g. left
    /// over from a previous schema). `count` and `dim` are reported
    /// alongside so the caller can validate against `DocumentRecord`.
    func loadVectors(documentID: UUID) throws -> (vectors: [[Float]], dim: Int)? {
        let url = storage.indexURL.appendingPathComponent("vectors-\(documentID.uuidString).bin")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count >= 16 else { return nil }
        let magic = Array(data.prefix(4))
        guard magic == Self.vectorMagic else { return nil }
        let version = readUInt32(data, at: 4)
        let count = Int(readUInt32(data, at: 8))
        let dim = Int(readUInt32(data, at: 12))
        guard version == Self.vectorVersion, dim > 0 else { return nil }
        let expected = 16 + count * dim * MemoryLayout<Float>.size
        guard data.count == expected else { return nil }

        var vectors = [[Float]]()
        vectors.reserveCapacity(count)
        for i in 0..<count {
            let start = 16 + i * dim * MemoryLayout<Float>.size
            var v = [Float](repeating: 0, count: dim)
            v.withUnsafeMutableBufferPointer { buf in
                data.copyBytes(
                    to: buf,
                    from: start..<(start + dim * MemoryLayout<Float>.size)
                )
            }
            vectors.append(v)
        }
        return (vectors, dim)
    }

    // MARK: - Generic helpers

    private func readArray<T: Decodable>(_ type: T.Type, from file: String) throws -> [T] {
        let url = storage.indexURL.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try decoder.decode([T].self, from: data)
    }

    private func writeArray<T: Encodable>(_ values: [T], to file: String) throws {
        let url = storage.indexURL.appendingPathComponent(file)
        let data = try encoder.encode(values)
        try data.write(to: url, options: .atomic)
    }

    private func removeIfExists(_ file: String) throws {
        let url = storage.indexURL.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: value)
    }
}
