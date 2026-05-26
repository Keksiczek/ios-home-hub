import Foundation
import UniformTypeIdentifiers

/// Orchestrates the parsing → chunking → embedding → indexing
/// pipeline for one `IngestJob` at a time.
///
/// ## Restartability
/// Every step writes its progress back to disk before moving on:
/// - the document record's `indexingStatus` advances through the
///   states (parsing → chunking → embedding → indexing → indexed)
/// - chunks are written before embeddings begin
/// - vectors are written in batches; on resume, the pipeline can
///   skip the chunks already covered by the persisted vector file
/// On launch, the scheduler asks the pipeline to drain pending
/// jobs; any job whose status was `processing` when the app died
/// is picked up first (see `IngestJobStore.fetchPending`).
///
/// ## Batch sizing
/// Embedding is the expensive step. We cap each "tick" of the
/// pipeline at `embeddingBatchSize` chunks so:
/// - a BGProcessingTask doesn't blow its time budget on one giant
///   PDF and orphan the rest of the queue
/// - the foreground caller can interleave UI updates between batches
///   without blocking the main thread
actor IngestPipeline {

    // MARK: - Config

    /// Per-tick batch size. 32 chunks ≈ 32 ms × 32 = ~1 s of
    /// embedding work on Apple Silicon — small enough to fit many
    /// batches inside a single `BGProcessingTask` window, big enough
    /// that the per-batch JSON write isn't dominant.
    static let embeddingBatchSize = 32

    /// Cap on file size we accept for ingestion. Larger files would
    /// block the pipeline for minutes; for v1 the user can split
    /// them externally. Bumping this is a future call once we have
    /// page-aware streaming for PDFs.
    static let maxIngestableBytes: Int64 = 64 * 1024 * 1024 // 64 MB

    // MARK: - Dependencies

    private let storage: SharedStorage
    private let documentStore: KnowledgeBaseStore
    private let jobStore: IngestJobStore
    private let embedder: DocumentEmbedder

    init(
        storage: SharedStorage,
        documentStore: KnowledgeBaseStore,
        jobStore: IngestJobStore,
        embedder: DocumentEmbedder
    ) {
        self.storage = storage
        self.documentStore = documentStore
        self.jobStore = jobStore
        self.embedder = embedder
    }

    // MARK: - Public API

    /// Drains pending jobs until either:
    /// - the queue is empty,
    /// - `shouldContinue()` returns false (BGTask budget about to
    ///   expire, foreground task cancelled, etc.).
    ///
    /// Returns the number of jobs that finished (`indexed` or
    /// `failed`) during this drain.
    @discardableResult
    func drainPending(
        maxJobs: Int = 32,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async -> Int {
        var finished = 0
        do {
            let pending = try await jobStore.fetchPending(limit: maxJobs)
            for job in pending {
                guard shouldContinue() else { break }
                await processJob(job, shouldContinue: shouldContinue)
                finished += 1
                // Yield between jobs so a foreground drain that
                // consumes a 50-PDF backlog doesn't starve the UI
                // task scheduler. Inside one job we already yield
                // implicitly via every `await documentStore.upsert`.
                await Task.yield()
            }
        } catch {
            HHLog.kb.error("ingest drain failed: \(error.localizedDescription, privacy: .public)")
        }
        return finished
    }

    /// Force-reindex an existing document. Used by the debug screen
    /// and by maintenance flows (e.g. embedding-model upgrade).
    func reindex(documentID: UUID) async {
        do {
            guard var doc = try await documentStore.loadDocuments()
                .first(where: { $0.id == documentID }) else { return }
            doc.indexingStatus = .queued
            doc.errorMessage = nil
            try await documentStore.upsert(document: doc)
            _ = await runIngest(document: doc, shouldContinue: { true })
        } catch {
            HHLog.kb.error("reindex failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Helper for the host app's in-app import flow: register a
    /// local file as a document, queue the corresponding job, and
    /// kick off ingest immediately. Returns the freshly-written job.
    @discardableResult
    func enqueueLocalFile(
        at sourceURL: URL,
        title: String?,
        sourceType: DocumentSourceType = .inAppImport,
        workspaceID: String? = nil,
        action: IngestAction = .saveToKnowledgeBase
    ) async throws -> IngestJob {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: sourceURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw NSError(
                domain: "IngestPipeline",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Soubor je prázdný."
                ]
            )
        }
        guard size <= Self.maxIngestableBytes else {
            // Spell out the cap in MB so the user understands what
            // changed when we bump the limit later. The previous
            // message just dumped raw bytes which is unreadable.
            let capMB = Self.maxIngestableBytes / (1024 * 1024)
            let actualMB = size / (1024 * 1024)
            throw NSError(
                domain: "IngestPipeline",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Soubor (\(actualMB) MB) přesahuje aktuální limit \(capMB) MB."
                ]
            )
        }
        // Refuse the import if the App Group volume can't host both
        // the canonical file copy AND a vector blob (~1× file size
        // is a generous over-estimate for v1 — chunks + Float32
        // averages out smaller than the source). Without this check
        // a low-storage device would copy the file, run the whole
        // pipeline, then fail on the vector write step with a
        // confusing "no such file" error.
        try Self.preflightDiskSpace(needed: size * 2, at: storage.filesURL)

        // Copy into the canonical kb/files location so the source
        // (e.g. iOS Files app temp dir) can disappear without
        // breaking ingest.
        let destFilename = "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
        let destURL = storage.filesURL.appendingPathComponent(destFilename)
        let didStartScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { sourceURL.stopAccessingSecurityScopedResource() } }
        try fm.copyItem(at: sourceURL, to: destURL)

        let hash = try SharedStorage.sha256(of: destURL)
        let mime = mimeType(for: destURL)
        let relPath = storage.relativePath(for: destURL) ?? destURL.path

        let job = IngestJob(
            id: UUID(),
            createdAt: .now,
            updatedAt: .now,
            sourceType: sourceType,
            workspaceID: workspaceID,
            action: action,
            status: .queued,
            title: title ?? sourceURL.deletingPathExtension().lastPathComponent,
            sourceAppBundleID: nil,
            originalURL: sourceURL,
            localPayloadRelativePath: relPath,
            mimeType: mime,
            contentHash: hash,
            errorMessage: nil,
            documentID: nil
        )
        try await jobStore.upsert(job)
        return job
    }

    // MARK: - Per-job state machine

    private func processJob(
        _ job: IngestJob,
        shouldContinue: @Sendable () -> Bool
    ) async {
        var working = job
        working.status = .processing
        working.updatedAt = .now
        try? await jobStore.upsert(working)

        do {
            // 1) Resolve / create document record.
            let document = try await ensureDocument(for: working)
            working.documentID = document.id
            try await jobStore.upsert(working)

            // 2) Run the ingest state machine on the document.
            let finalDoc = await runIngest(document: document, shouldContinue: shouldContinue)

            // 3) Finalise the job.
            working.status = finalDoc.indexingStatus == .indexed ? .indexed : .failed
            working.errorMessage = finalDoc.errorMessage
            working.updatedAt = .now
            try await jobStore.upsert(working)
        } catch {
            HHLog.kb.error("ingest job \(working.id) failed: \(error.localizedDescription, privacy: .public)")
            working.status = .failed
            working.errorMessage = error.localizedDescription
            working.updatedAt = .now
            try? await jobStore.upsert(working)
        }
    }

    /// Find an existing `DocumentRecord` for this content hash or
    /// create a fresh one. The hash dedupe means a user re-sharing
    /// the same PDF doesn't blow up the index with duplicates.
    private func ensureDocument(for job: IngestJob) async throws -> DocumentRecord {
        // Reuse-by-id (a previous run was interrupted mid-ingest).
        if let docID = job.documentID,
           let existing = try await documentStore.loadDocuments().first(where: { $0.id == docID }) {
            return existing
        }
        // Reuse-by-hash (deduplication).
        if let existing = try await documentStore.document(forSHA256: job.contentHash) {
            return existing
        }

        guard let relPath = job.localPayloadRelativePath else {
            throw NSError(
                domain: "IngestPipeline",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Job nemá payload."]
            )
        }
        let absURL = try storage.absoluteURL(forRelativePath: relPath)
        let fm = FileManager.default
        let size = ((try fm.attributesOfItem(atPath: absURL.path))[.size] as? NSNumber)?.int64Value ?? 0

        let doc = DocumentRecord(
            id: UUID(),
            workspaceID: job.workspaceID,
            title: job.title ?? absURL.deletingPathExtension().lastPathComponent,
            sourceType: job.sourceType,
            sourceURL: job.originalURL,
            relativeFilePath: relPath,
            sha256: job.contentHash,
            fileSize: size,
            mimeType: job.mimeType ?? mimeType(for: absURL),
            createdAt: .now,
            indexingStatus: .queued,
            chunkCount: 0,
            embeddingDimension: nil,
            parserVersion: KBVersions.parser,
            chunkingVersion: KBVersions.chunking,
            embeddingModelID: embedder.modelID,
            embeddingVersion: embedder.version,
            lastIndexedAt: nil,
            errorMessage: nil
        )
        try await documentStore.upsert(document: doc)
        return doc
    }

    /// The actual parsing → chunking → embedding → indexing state
    /// machine. Persists the document after every transition so a
    /// crash mid-flight resumes from the latest persisted status.
    /// Returns the final document state (caller decides what to do
    /// with it — e.g. update the parent `IngestJob`).
    private func runIngest(
        document initialDocument: DocumentRecord,
        shouldContinue: @Sendable () -> Bool
    ) async -> DocumentRecord {
        var document = initialDocument
        do {
            let absURL = try storage.absoluteURL(forRelativePath: document.relativeFilePath)

            // Parse — page-streaming. For PDFs this never holds the
            // entire concatenated document text in memory; for plain
            // text/markdown it returns a single `PageText` so the
            // chunking path is uniform.
            document.indexingStatus = .parsing
            try await documentStore.upsert(document: document)
            // OCR fallback path so scanned PDFs (no text layer)
            // still ingest into the KB. Falls back transparently
            // when the textual layer is missing; pays no OCR cost
            // for normal text PDFs.
            let pages = try await DocumentReaderService.extractPagesWithOCRFallback(from: absURL)
            guard !pages.isEmpty else {
                throw NSError(
                    domain: "IngestPipeline",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Z dokumentu se nepodařilo extrahovat text."]
                )
            }

            // Chunk per page. Chunks stay within page boundaries so
            // every `ChunkRecord.pageNumber` is exact for citations.
            document.indexingStatus = .chunking
            try await documentStore.upsert(document: document)
            let chunks = DocumentChunker.chunks(forPages: pages, documentID: document.id)
            try await documentStore.saveChunks(chunks, documentID: document.id)
            document.chunkCount = chunks.count

            // Embed.
            document.indexingStatus = .embedding
            try await documentStore.upsert(document: document)
            var allVectors: [[Float]] = []
            allVectors.reserveCapacity(chunks.count)
            var idx = 0
            let embedStart = Date()
            while idx < chunks.count {
                guard shouldContinue() else {
                    // Soft exit: persist what we have for resume,
                    // leave status at .embedding so the next drain
                    // restarts from the parse step (chunk file on
                    // disk is reused, but vectors will be redone).
                    HHLog.kb.notice("ingest yield: time budget exhausted at chunk \(idx, privacy: .public)/\(chunks.count, privacy: .public)")
                    return document
                }
                let end = min(idx + Self.embeddingBatchSize, chunks.count)
                let slice = Array(chunks[idx..<end])
                let results = await embedder.embed(
                    texts: slice.map(\.text),
                    chunkIDs: slice.map(\.id)
                )
                for r in results { allVectors.append(r.vector) }
                idx = end
                // Yield between embedding batches so a foreground
                // ingest of a 1000-chunk doc doesn't starve the UI
                // task scheduler. The actual embedding work happens
                // inside `embedder.embed`, which already awaits the
                // NLContextualEmbedding model — this yield just
                // gives queued main-actor work a slot before we
                // grab the next batch.
                await Task.yield()
            }

            // Index — write vectors blob.
            document.indexingStatus = .indexing
            try await documentStore.upsert(document: document)

            // Defensive: assert dimension uniformity before persisting.
            // `KnowledgeBaseStore.saveVectors` packs each vector into a
            // fixed-stride Float32 blob keyed off the first row's
            // count — a downstream variable-dimension surprise would
            // silently truncate later rows on read. Embedders are
            // expected to be deterministic, but the cost of validating
            // here is one O(n) scan and the cost of NOT validating is
            // a corrupt index that produces nonsensical retrieval.
            if let expected = allVectors.first?.count,
               let mismatchIdx = allVectors.firstIndex(where: { $0.count != expected }) {
                throw NSError(
                    domain: "IngestPipeline",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Vektory mají nejednotnou dimenzi (chunk \(mismatchIdx): \(allVectors[mismatchIdx].count) vs. \(expected))."]
                )
            }

            try await documentStore.saveVectors(allVectors, documentID: document.id)
            document.embeddingDimension = allVectors.first?.count

            // Throughput log — pairs with the MLX/llama.cpp generation
            // logs so a slow ingest is correlatable with concurrent
            // load on the embedding model. Total wall-clock includes
            // the per-batch Task.yield + actor hops, not just embed work.
            let elapsed = Date().timeIntervalSince(embedStart)
            if elapsed > 0 {
                let chunksPerSec = Double(chunks.count) / elapsed
                HHLog.kb.info("ingest embed: doc=\(document.id, privacy: .public) chunks=\(chunks.count, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s rate=\(String(format: "%.1f", chunksPerSec), privacy: .public) chunks/s")
            }

            // Done.
            document.indexingStatus = .indexed
            document.lastIndexedAt = .now
            document.errorMessage = nil
            try await documentStore.upsert(document: document)
        } catch {
            document.indexingStatus = .failed
            document.errorMessage = error.localizedDescription
            try? await documentStore.upsert(document: document)
            HHLog.kb.error("ingest doc \(document.id) failed: \(error.localizedDescription, privacy: .public)")
        }
        return document
    }

    // MARK: - Helpers

    private func mimeType(for url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension),
           let mime = utType.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    /// Throws if the volume backing `directory` doesn't have at
    /// least `needed` bytes free. Uses `volumeAvailableCapacityFor
    /// ImportantUsage` because that's what the system promises to
    /// hand us under disk-space pressure (vs. the raw available
    /// capacity which iOS may purge before granting).
    private static func preflightDiskSpace(needed: Int64, at directory: URL) throws {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        let values = try directory.resourceValues(forKeys: keys)
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            // The key is best-effort — on volumes that don't report
            // it (rare on iOS) we fall back to allowing the import
            // and let the actual write fail loudly later.
            return
        }
        guard available >= needed else {
            let neededMB = needed / (1024 * 1024)
            let availableMB = available / (1024 * 1024)
            throw NSError(
                domain: "IngestPipeline",
                code: -10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Nedostatek místa: potřeba \(neededMB) MB, k dispozici \(availableMB) MB."
                ]
            )
        }
    }
}
