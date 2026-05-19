import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeBaseView: View {
    @EnvironmentObject private var knowledgeBase: KnowledgeBaseService
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var container: AppContainer

    @State private var importing = false
    @State private var pendingError: String?
    @State private var spotlightStatusMessage: String?
    @State private var highlightedDocumentID: UUID?
    @State private var showDeveloperOptions = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: HHTheme.spaceXL) {
                    headerSection
                    statsSection
                    
                    if let error = knowledgeBase.bootstrapError {
                        errorBanner(error)
                    }

                    if !knowledgeBase.jobs.isEmpty {
                        jobsSection
                    }
                    
                    documentsSection
                    
                    if showDeveloperOptions {
                        developerSection
                    } else {
                        Button("Developer Options") {
                            withAnimation { showDeveloperOptions = true }
                        }
                        .font(HHTheme.footnote)
                        .foregroundStyle(HHTheme.textSecondary)
                        .padding(.top, HHTheme.spaceL)
                    }
                }
                .padding(.horizontal, HHTheme.spaceL)
                .padding(.vertical, HHTheme.spaceM)
            }
            .background(HHTheme.canvas)
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarMenuButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        importing = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        Task { await knowledgeBase.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
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
            .alert("Import Error", isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } }
            ), presenting: pendingError) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
            .task {
                await knowledgeBase.refresh()
                consumePendingDeepLinkIfMatching(proxy: proxy)
            }
            .onChange(of: appState.pendingDeepLink) { _, _ in
                consumePendingDeepLinkIfMatching(proxy: proxy)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Knowledge Base")
                .font(HHTheme.largeTitle)
                .foregroundStyle(HHTheme.textPrimary)
            Text("Documents imported here are searchable by the assistant.")
                .font(HHTheme.body)
                .foregroundStyle(HHTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statsSection: some View {
        HStack(spacing: HHTheme.spaceM) {
            statCard(title: "Documents", value: "\(knowledgeBase.documents.count)", icon: "doc.on.doc")
            let chunkCount = knowledgeBase.documents.map { $0.chunkCount }.reduce(0, +)
            statCard(title: "Chunks Indexed", value: "\(chunkCount)", icon: "text.alignleft")
            statCard(title: "Active Jobs", value: "\(knowledgeBase.jobs.count)", icon: "arrow.triangle.2.circlepath")
        }
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceS) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(HHTheme.accent)
            Text(value)
                .font(HHTheme.title2)
                .foregroundStyle(HHTheme.textPrimary)
            Text(title)
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HHTheme.spaceL)
        .hhCard()
    }

    @ViewBuilder
    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            HStack {
                Text("Ingestion Queue")
                    .font(HHTheme.title3)
                Spacer()
                if knowledgeBase.jobs.contains(where: { $0.status == .failed }) {
                    Button("Clear Failed", role: .destructive) {
                        Task { await knowledgeBase.clearFailedJobs() }
                    }
                    .font(HHTheme.footnote)
                }
            }
            ForEach(knowledgeBase.jobs) { job in
                jobRow(job)
            }
        }
    }

    @ViewBuilder
    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            Text("Documents (\(knowledgeBase.documents.count))")
                .font(HHTheme.title3)
            
            if knowledgeBase.documents.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: HHTheme.spaceM) {
                        Image(systemName: "tray")
                            .font(.system(size: 40))
                            .foregroundStyle(HHTheme.textSecondary.opacity(0.5))
                        Text("No documents yet")
                            .font(HHTheme.headline)
                        Text("Tap + to import a PDF or text file.")
                            .font(HHTheme.caption)
                            .foregroundStyle(HHTheme.textSecondary)
                    }
                    .padding(.vertical, HHTheme.spaceXL)
                    Spacer()
                }
                .hhCard()
            } else {
                LazyVStack(spacing: HHTheme.spaceM) {
                    ForEach(knowledgeBase.documents) { doc in
                        documentRow(doc)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func errorBanner(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HHTheme.danger)
            Text(error)
                .font(HHTheme.subheadline)
                .foregroundStyle(HHTheme.danger)
            Spacer()
        }
        .padding(HHTheme.spaceM)
        .background(HHTheme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: HHTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: HHTheme.cornerMedium)
                .stroke(HHTheme.danger.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Rows

    @ViewBuilder
    private func documentRow(_ doc: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceS) {
            HStack {
                Image(systemName: doc.mimeType.contains("pdf") ? "doc.richtext.fill" : "doc.text.fill")
                    .font(.title2)
                    .foregroundStyle(HHTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title)
                        .font(HHTheme.headline)
                        .foregroundStyle(HHTheme.textPrimary)
                    HStack(spacing: 6) {
                        Text("\(doc.chunkCount) chunks")
                        Text("·")
                        Text(byteFormatter.string(fromByteCount: doc.fileSize))
                        Text("·")
                        Text(doc.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
                }
                Spacer()
                statusBadge(for: doc.indexingStatus)
            }
            
            if let err = doc.errorMessage {
                Text(err)
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.danger)
            }
            
            HStack(spacing: HHTheme.spaceM) {
                Button("Reindex") {
                    Task { await knowledgeBase.reindex(documentID: doc.id) }
                }
                .tint(HHTheme.accent)
                
                Button("Delete", role: .destructive) {
                    Task { await knowledgeBase.deleteDocument(doc.id) }
                }
            }
            .font(HHTheme.subheadline)
            .buttonStyle(.bordered)
        }
        .padding(HHTheme.spaceM)
        .background(
            highlightedDocumentID == doc.id ? HHTheme.warning.opacity(0.15) : HHTheme.surface,
            in: RoundedRectangle(cornerRadius: HHTheme.cornerMedium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HHTheme.cornerMedium)
                .stroke(HHTheme.stroke, lineWidth: 1)
        )
        .id(doc.id)
    }

    @ViewBuilder
    private func jobRow(_ job: IngestJob) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title ?? "(Untitled)")
                    .font(HHTheme.subheadline.weight(.semibold))
                    .foregroundStyle(HHTheme.textPrimary)
                Text("Action: \(job.action.rawValue)")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
                if let err = job.errorMessage {
                    Text(err)
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.danger)
                }
            }
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                jobStatusBadge(for: job.status)
                if job.status == .failed || job.status == .awaitingApp {
                    Button("Retry") {
                        Task { await knowledgeBase.retry(jobID: job.id) }
                    }
                    .font(HHTheme.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(HHTheme.spaceM)
        .background(HHTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: HHTheme.cornerSmall))
    }

    // MARK: - Developer Options
    
    @ViewBuilder
    private var developerSection: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            Text("Developer Options")
                .font(HHTheme.headline)
            
            Button("Rebuild Spotlight Index") {
                Task { await rebuildSpotlight() }
            }
            .buttonStyle(.bordered)
            
            if let msg = spotlightStatusMessage {
                Text(msg)
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
            }
            
            if !knowledgeBase.pendingShareRequests.isEmpty {
                Text("Shared Inbox (\(knowledgeBase.pendingShareRequests.count))")
                    .font(HHTheme.subheadline.weight(.semibold))
                ForEach(knowledgeBase.pendingShareRequests) { req in
                    Text("Action: \(req.action) · \(req.status.rawValue)")
                        .font(HHTheme.caption.monospaced())
                        .foregroundStyle(HHTheme.textSecondary)
                }
            }
        }
        .padding(HHTheme.spaceM)
        .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: HHTheme.cornerMedium))
    }

    // MARK: - Status Badges

    private func statusBadge(for status: DocumentIndexingStatus) -> some View {
        let (color, icon) = documentBadgeStyle(for: status)
        return Label(status.rawValue.capitalized, systemImage: icon)
            .font(HHTheme.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func documentBadgeStyle(for status: DocumentIndexingStatus) -> (Color, String) {
        switch status {
        case .indexed: return (HHTheme.success, "checkmark.circle.fill")
        case .failed: return (HHTheme.danger, "xmark.circle.fill")
        case .notIndexed, .queued: return (HHTheme.textSecondary, "clock.fill")
        case .parsing, .chunking, .embedding, .indexing: return (HHTheme.warning, "arrow.triangle.2.circlepath")
        }
    }

    private func jobStatusBadge(for status: IngestStatus) -> some View {
        Text(status.rawValue.capitalized)
            .font(HHTheme.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(jobBackground(for: status), in: Capsule())
            .foregroundStyle(.primary)
    }

    private func jobBackground(for status: IngestStatus) -> Color {
        switch status {
        case .indexed: return HHTheme.success.opacity(0.2)
        case .failed: return HHTheme.danger.opacity(0.2)
        case .queued, .awaitingApp: return HHTheme.textSecondary.opacity(0.2)
        case .processing: return HHTheme.warning.opacity(0.2)
        }
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f
    }

    // MARK: - Actions

    @MainActor
    private func rebuildSpotlight() async {
        spotlightStatusMessage = "Wiping..."
        let docs = knowledgeBase.documents
        let convs = container.conversationService.conversations
        let facts = container.memoryService.facts
        await container.searchIndexingService.wipeAll()
        await container.searchIndexingService.bootstrap(
            documents: docs,
            conversations: convs,
            memoryFacts: facts
        )
        spotlightStatusMessage = "Reindexed \(docs.count) docs · \(convs.count) chats · \(facts.count) facts."
    }

    private func consumePendingDeepLinkIfMatching(proxy: ScrollViewProxy) {
        guard case .document(let id) = appState.pendingDeepLink else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .top) }
            highlightedDocumentID = id
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { highlightedDocumentID = nil }
        }
        appState.clearPendingDeepLink()
    }
}

#Preview {
    NavigationStack {
        KnowledgeBaseView()
            .environmentObject(AppContainer.preview().knowledgeBaseService)
            .environmentObject(AppContainer.preview().appState)
            .environmentObject(AppContainer.preview())
    }
}
