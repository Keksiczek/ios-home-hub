import SwiftUI
import UniformTypeIdentifiers

/// Minimal debug surface for the Knowledge Base. Lists every tracked
/// document and ingest job, lets the developer / power-user retry,
/// reindex, or delete entries, and includes a "+ Import file"
/// button for ingesting a local file straight from the host app
/// without going through the Share Extension.
///
/// Intentionally not in the main tab bar — surfaced via Settings /
/// the sidebar so it doesn't expose the WIP UI to regular users.
struct KnowledgeBaseDebugView: View {
    @EnvironmentObject private var knowledgeBase: KnowledgeBaseService
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var container: AppContainer

    @State private var importing = false
    @State private var pendingError: String?
    @State private var spotlightStatusMessage: String?
    /// Highlighted document ID — set when a Spotlight tap or
    /// `homehub://document/<UUID>` URL drops a deep link in. Used
    /// both to scroll-to and to render a brief background flash on
    /// the matching row.
    @State private var highlightedDocumentID: UUID?

    var body: some View {
        // ScrollViewReader so a deep link can scroll-to the
        // target document. The List rows tag themselves with
        // their UUID via `.id(...)` below.
        ScrollViewReader { proxy in
        List {
            if let error = knowledgeBase.bootstrapError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } header: {
                    Text("Bootstrap")
                }
            }

            Section("Sdílené (\(knowledgeBase.pendingShareRequests.count))") {
                if knowledgeBase.pendingShareRequests.isEmpty {
                    Text("Inbox je prázdný.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knowledgeBase.pendingShareRequests) { request in
                        shareRequestRow(request)
                    }
                }
            }

            Section("Dokumenty (\(knowledgeBase.documents.count))") {
                if knowledgeBase.documents.isEmpty {
                    Text("Zatím žádné dokumenty.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knowledgeBase.documents) { doc in
                        documentRow(doc)
                    }
                }
            }

            Section("Joby (\(knowledgeBase.jobs.count))") {
                if knowledgeBase.jobs.isEmpty {
                    Text("Žádné joby.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knowledgeBase.jobs) { job in
                        jobRow(job)
                    }
                }

                if knowledgeBase.jobs.contains(where: { $0.status == .failed }) {
                    Button("Vymazat selhané joby", role: .destructive) {
                        Task { await knowledgeBase.clearFailedJobs() }
                    }
                }
            }

            Section {
                // Surfaced as a debug action because the bootstrap
                // flag (in UserDefaults) suppresses normal full
                // reindexing. Without this button, recovering from
                // an incoherent Spotlight state would require app
                // delete + reinstall.
                Button("Rebuild Spotlight index") {
                    Task { await rebuildSpotlight() }
                }
                if let msg = spotlightStatusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Spotlight")
            } footer: {
                Text("Drops every Home Hub entry from system Spotlight and re-pushes documents, conversations, and memory facts. Useful after a manual data wipe or when the index falls out of sync.")
            }
        }
        .navigationTitle("Knowledge Base")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importing = true
                } label: {
                    Label("Importovat soubor", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Task { await knowledgeBase.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.pdf, .plainText, .text, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    do {
                        try await knowledgeBase.importFile(at: url)
                    } catch {
                        pendingError = error.localizedDescription
                    }
                }
            case .failure(let error):
                pendingError = error.localizedDescription
            }
        }
        .alert(
            "Chyba importu",
            isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } }
            ),
            presenting: pendingError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .task {
            await knowledgeBase.refresh()
            // Cold-launch deep link: AppState already has the
            // pending link by the time the view appears.
            consumePendingDeepLinkIfMatching(proxy: proxy)
        }
        .onChange(of: appState.pendingDeepLink) { _, _ in
            consumePendingDeepLinkIfMatching(proxy: proxy)
        }
        } // ScrollViewReader
    }

    /// Wipes everything the app has indexed in Spotlight, then
    /// rebuilds from current in-memory state. The `wipeAll()`
    /// call also clears the bootstrap-done flag so the next
    /// `bootstrap(...)` call here can re-fire.
    @MainActor
    private func rebuildSpotlight() async {
        spotlightStatusMessage = "Wiping…"
        let docs = knowledgeBase.documents
        let convs = container.conversationService.conversations
        let facts = container.memoryService.facts
        await container.searchIndexingService.wipeAll()
        await container.searchIndexingService.bootstrap(
            documents: docs,
            conversations: convs,
            memoryFacts: facts
        )
        spotlightStatusMessage =
            "Reindexed \(docs.count) docs · \(convs.count) chats · \(facts.count) facts."
    }

    /// Pulls a `.document(id)` deep link off `AppState`, scrolls
    /// the matching row into view, sets it as the highlighted
    /// row for a brief flash, then clears the pending link.
    /// No-op for any other deep-link case.
    private func consumePendingDeepLinkIfMatching(proxy: ScrollViewProxy) {
        guard case .document(let id) = appState.pendingDeepLink else { return }
        // Scroll on the next runloop tick so the List has had a
        // chance to render the rows under their `.id(…)` tags.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .top) }
            highlightedDocumentID = id
        }
        // Auto-fade the highlight after ~1.5 s.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { highlightedDocumentID = nil }
        }
        appState.clearPendingDeepLink()
    }

    @ViewBuilder
    private func shareRequestRow(_ request: ShareRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(request.action)
                    .font(.body.weight(.medium))
                Spacer()
                Text(request.status.rawValue)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(shareBackground(for: request.status))
                    .clipShape(Capsule())
            }
            Text("payload \(request.payloadID.uuidString.prefix(8))…")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if let err = request.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func shareBackground(for status: ShareRequestStatus) -> Color {
        switch status {
        case .stored, .queued: return .gray.opacity(0.2)
        case .consumedByApp:   return .green.opacity(0.2)
        case .failed:          return .red.opacity(0.2)
        }
    }

    @ViewBuilder
    private func documentRow(_ doc: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(doc.title)
                    .font(.body.weight(.medium))
                Spacer()
                statusBadge(for: doc.indexingStatus)
            }
            HStack(spacing: 8) {
                Text("\(doc.chunkCount) chunků")
                Text("·")
                Text(byteFormatter.string(fromByteCount: doc.fileSize))
                Text("·")
                Text(doc.mimeType)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let err = doc.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Reindex") {
                    Task { await knowledgeBase.reindex(documentID: doc.id) }
                }
                Button("Smazat", role: .destructive) {
                    Task { await knowledgeBase.deleteDocument(doc.id) }
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
        // `.id(doc.id)` so `ScrollViewReader.scrollTo(doc.id, …)`
        // can target this row from the deep-link consumer above.
        .id(doc.id)
        // Brief background flash on the deep-link target row
        // so the user can see *which* document was hit even if
        // the list scrolled to it without animation.
        .listRowBackground(
            highlightedDocumentID == doc.id
                ? Color.yellow.opacity(0.25)
                : Color(.secondarySystemGroupedBackground)
        )
    }

    @ViewBuilder
    private func jobRow(_ job: IngestJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.title ?? "(bez názvu)")
                    .font(.body.weight(.medium))
                Spacer()
                Text(job.status.rawValue)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(jobBackground(for: job.status))
                    .clipShape(Capsule())
            }
            Text("zdroj: \(job.sourceType.rawValue) · akce: \(job.action.rawValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let err = job.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if job.status == .failed || job.status == .awaitingApp {
                Button("Retry") {
                    Task { await knowledgeBase.retry(jobID: job.id) }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(for status: DocumentIndexingStatus) -> some View {
        Text(status.rawValue)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(documentBackground(for: status))
            .clipShape(Capsule())
    }

    private func documentBackground(for status: DocumentIndexingStatus) -> Color {
        switch status {
        case .indexed: return .green.opacity(0.2)
        case .failed: return .red.opacity(0.2)
        case .notIndexed, .queued: return .gray.opacity(0.2)
        case .parsing, .chunking, .embedding, .indexing: return .orange.opacity(0.2)
        }
    }

    private func jobBackground(for status: IngestStatus) -> Color {
        switch status {
        case .indexed: return .green.opacity(0.2)
        case .failed: return .red.opacity(0.2)
        case .queued, .awaitingApp: return .gray.opacity(0.2)
        case .processing: return .orange.opacity(0.2)
        }
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f
    }
}

#Preview {
    NavigationStack {
        KnowledgeBaseDebugView()
            .environmentObject(KnowledgeBaseService(embedding: EmbeddingService()))
    }
}
