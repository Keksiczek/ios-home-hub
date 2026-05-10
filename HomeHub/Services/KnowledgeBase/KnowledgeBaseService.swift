import Foundation
import SwiftUI

/// Top-level façade for the document Knowledge Base. Owns:
/// - the App Group `SharedStorage`,
/// - the persistence actors (`KnowledgeBaseStore`, `IngestJobStore`),
/// - the ingest `pipeline` and `retrieval` APIs,
/// - the `IngestScheduler` (which talks to BackgroundTasks).
///
/// Exposed on `AppContainer` so views/services can reach in via
/// `EnvironmentObject`. Publishes the visible state (documents and
/// jobs lists) so the debug screen / future Knowledge Base UI can
/// observe changes without polling.
@MainActor
final class KnowledgeBaseService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var documents: [DocumentRecord] = []
    @Published private(set) var jobs: [IngestJob] = []
    /// Pending share requests posted by the Share Extension that
    /// haven't yet been converted into ingest jobs. Surfaced in the
    /// inbox UI so the user sees recent shares even before the
    /// pipeline runs.
    @Published private(set) var pendingShareRequests: [ShareRequest] = []
    /// Set when something during init (most likely missing App Group
    /// entitlement) made the service unusable. Surfaced in the debug
    /// screen so onboarding can spot misconfigured signing.
    @Published private(set) var bootstrapError: String?

    // MARK: - Components

    let storage: SharedStorage?
    let documentStore: KnowledgeBaseStore?
    let jobStore: IngestJobStore?
    let pipeline: IngestPipeline?
    let retrieval: KnowledgeBaseRetrievalService?
    let scheduler: IngestScheduler?
    let payloadStore: SharePayloadStore?
    let shareBridge: ShareInboxBridge?

    /// Convenience: expose the retrieval as the protocol type so chat
    /// / agent code can depend on the abstraction.
    var retrievalAPI: (any KnowledgeBaseRetrieving)? { retrieval }

    init(embedding: EmbeddingService) {
        do {
            let storage = try SharedStorage()
            let docStore = KnowledgeBaseStore(storage: storage)
            let jobStore = IngestJobStore(storage: storage)
            let embedder = EmbeddingServiceDocumentEmbedder(embedder: embedding)
            let pipeline = IngestPipeline(
                storage: storage,
                documentStore: docStore,
                jobStore: jobStore,
                embedder: embedder
            )
            let retrieval = KnowledgeBaseRetrievalService(
                documentStore: docStore,
                embedder: embedding
            )
            let scheduler = IngestScheduler(pipeline: pipeline, jobStore: jobStore)
            let payloadStore = SharePayloadStore(storage: storage)
            let bridge = ShareInboxBridge(
                payloadStore: payloadStore,
                jobStore: jobStore,
                storage: storage
            )

            self.storage = storage
            self.documentStore = docStore
            self.jobStore = jobStore
            self.pipeline = pipeline
            self.retrieval = retrieval
            self.scheduler = scheduler
            self.payloadStore = payloadStore
            self.shareBridge = bridge
            self.bootstrapError = nil
        } catch {
            self.storage = nil
            self.documentStore = nil
            self.jobStore = nil
            self.pipeline = nil
            self.retrieval = nil
            self.scheduler = nil
            self.payloadStore = nil
            self.shareBridge = nil
            self.bootstrapError = error.localizedDescription
            HHLog.kb.error("KnowledgeBase bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Bootstrap / refresh

    /// Loads visible state and triggers an opportunistic foreground
    /// drain of any jobs queued since last launch. Called once from
    /// `AppContainer.bootstrap()`.
    ///
    /// Order matters:
    /// 1. Refresh visible state so the UI is responsive immediately.
    /// 2. Drain the Share Extension inbox → IngestJob queue. Has to
    ///    run *before* the ingest drain so requests posted between
    ///    launches make it into the same drain pass.
    /// 3. Drain ingest jobs.
    /// 4. Refresh again so the UI reflects the converted state.
    func bootstrap() async {
        await refresh()
        if let shareBridge {
            _ = await shareBridge.drain()
        }
        if let scheduler {
            await scheduler.drainForegroundIfPending()
        }
        await refresh()
    }

    /// Re-loads `documents` / `jobs` from disk. The persistence
    /// actors are the source of truth; the published arrays are
    /// just a snapshot for SwiftUI.
    func refresh() async {
        guard let documentStore, let jobStore else { return }
        do {
            let docs = try await documentStore.loadDocuments()
                .sorted { $0.createdAt > $1.createdAt }
            let pendingJobs = try await jobStore.loadAll()
                .sorted { $0.createdAt > $1.createdAt }
            let pendingShares = (try await payloadStore?.pendingRequests()) ?? []

            // Detect whether the documents set changed (added,
            // removed, or any indexing-status transition that the
            // cache would treat as fresh). If so, drop the in-memory
            // retrieval cache so the next query rebuilds from disk.
            let didChange = self.documents.count != docs.count
                || zip(self.documents, docs).contains(where: { $0.id != $1.id || $0.lastIndexedAt != $1.lastIndexedAt })
            if didChange {
                await retrieval?.invalidate()
            }

            self.documents = docs
            self.jobs = pendingJobs
            self.pendingShareRequests = pendingShares
        } catch {
            HHLog.kb.error("KB refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - User-facing operations (used by debug screen + import flow)

    /// Imports a local file synchronously (registers the document,
    /// queues a job, drains the pipeline). On a small text file this
    /// returns within a couple hundred ms; on a large PDF the
    /// pipeline yields and the caller can pop back to the UI while
    /// the rest finishes in the next foreground / BG drain.
    func importFile(at url: URL, title: String? = nil) async throws {
        guard let pipeline else { throw makeError("Knowledge Base není dostupný.") }
        _ = try await pipeline.enqueueLocalFile(at: url, title: title)
        await scheduler?.drainForegroundIfPending()
        await refresh()
    }

    func retry(jobID: UUID) async {
        guard let jobStore, let pipeline else { return }
        do {
            var all = try await jobStore.loadAll()
            guard let idx = all.firstIndex(where: { $0.id == jobID }) else { return }
            all[idx].status = .queued
            all[idx].errorMessage = nil
            all[idx].updatedAt = .now
            try await jobStore.upsert(all[idx])
            await pipeline.drainPending(maxJobs: 1, shouldContinue: { true })
            await refresh()
        } catch {
            HHLog.kb.error("KB retry job failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reindex(documentID: UUID) async {
        guard let pipeline else { return }
        await pipeline.reindex(documentID: documentID)
        await refresh()
    }

    func deleteDocument(_ documentID: UUID) async {
        guard let documentStore else { return }
        do {
            try await documentStore.deleteDocument(id: documentID)
            await refresh()
        } catch {
            HHLog.kb.error("KB delete doc failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearFailedJobs() async {
        guard let jobStore else { return }
        do {
            let all = try await jobStore.loadAll()
            for job in all where job.status == .failed {
                try await jobStore.delete(id: job.id)
            }
            await refresh()
        } catch {
            HHLog.kb.error("KB clear failed jobs failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Lifecycle hooks

    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            scheduler?.scheduleIfNeeded()
        case .active:
            // Same drain order as `bootstrap()`: extension inbox →
            // ingest pipeline → refresh. New shares posted while
            // the app was inactive get picked up here.
            if let shareBridge {
                _ = await shareBridge.drain()
            }
            await scheduler?.drainForegroundIfPending()
            await refresh()
        default:
            break
        }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(
            domain: "KnowledgeBaseService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
