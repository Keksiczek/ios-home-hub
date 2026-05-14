import SwiftUI
import UIKit

struct ModelsView: View {
    @EnvironmentObject private var catalog:   ModelCatalogService
    @EnvironmentObject private var downloads: ModelDownloadService
    @EnvironmentObject private var runtime:   RuntimeManager
    @EnvironmentObject private var settings:  SettingsService

    /// Collapses multi-source state into per-row `ModelBrowserStatus` values
    /// and debounces at 50 ms so 10 Hz progress ticks don't rebuild the list.
    @StateObject private var vm = ModelBrowserViewModel()

    private var isRunningOnPhone: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    @State private var downloadTarget: LocalModel?
    @State private var infoTarget:     LocalModel?
    @State private var deleteTarget:   LocalModel?
    @State private var showAddFromURL  = false
    @State private var availableBytes: Int64 = 0
    @State private var searchText      = ""

    // MARK: - Disk stats

    private func refreshAvailableBytes() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v   = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        availableBytes = v?.volumeAvailableCapacityForImportantUsage.map { Int64($0) } ?? 0
    }

    private func hasSufficientSpace(for model: LocalModel) -> Bool {
        guard model.sizeBytes > 0 else { return true }
        return availableBytes >= Int64(Double(model.sizeBytes) * 1.1)
    }

    // MARK: - Section helpers

    /// Filters `vm.sections` by the current search text (no re-sort; stable order).
    private var filteredSections: [ModelBrowserSection] {
        guard !searchText.isEmpty else { return vm.sections }
        return vm.sections.compactMap { section in
            let filtered = section.items.filter {
                $0.model.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.model.family.localizedCaseInsensitiveContains(searchText)
            }
            guard !filtered.isEmpty else { return nil }
            return ModelBrowserSection(kind: section.kind, items: filtered)
        }
    }

    private var onDeviceItems: [ModelBrowserItem] {
        vm.sections.first(where: { $0.kind == .onDevice })?.items ?? []
    }

    private var storageFooterText: String {
        let usedBytes = onDeviceItems.reduce(Int64(0)) { $0 + $1.model.sizeBytes }
        let used = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: max(availableBytes, 0), countStyle: .file)
        return "\(used) used by installed models · \(free) free"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSections) { section in
                    Section {
                        ForEach(section.items) { item in
                            ModelBrowserRow(
                                item:              item,
                                isRunningOnPhone:  isRunningOnPhone,
                                onDownload:        { downloadTarget = item.model },
                                onCancel:          { downloads.cancel(item.model.id) },
                                onLoad: {
                                    Task {
                                        await runtime.load(item.model)
                                        await settings.set(\.selectedModelID, to: item.model.id)
                                    }
                                },
                                onUnload:          { Task { await runtime.unload() } },
                                onCancelMLXLoad:   { runtime.cancelMLXLoad() },
                                onDelete:          { deleteTarget = item.model },
                                onInfo:            { infoTarget   = item.model }
                            )
                        }
                    } header: {
                        Text(section.headerText)
                    } footer: {
                        if section.kind == .onDevice {
                            Text(storageFooterText)
                        } else {
                            Text(section.footerText)
                        }
                    }
                }

                // Empty state — shown only when no sections at all.
                if filteredSections.isEmpty {
                    Section {
                        VStack(alignment: .center, spacing: HHTheme.spaceM) {
                            Image(systemName: "cube.box")
                                .font(.system(size: 40))
                                .foregroundStyle(HHTheme.textSecondary.opacity(0.4))
                            Text("No models yet")
                                .font(HHTheme.headline)
                            Text("Download a model from the catalog or add one directly by URL.")
                                .font(HHTheme.caption)
                                .foregroundStyle(HHTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HHTheme.spaceXL)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Models")
            .searchable(text: $searchText, prompt: "Search models")
            .refreshable {
                refreshAvailableBytes()
                await downloads.reconcileInstallStates()
            }
            .onAppear {
                // Connect the view-model once; idempotent on subsequent appearances.
                vm.connect(catalog: catalog, downloads: downloads, runtime: runtime)
                refreshAvailableBytes()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarMenuButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddFromURL = true } label: {
                        Label("Add from URL", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $infoTarget) { model in
                ModelInfoSheet(model: model)
            }
            .sheet(isPresented: $showAddFromURL) {
                AddFromURLSheet()
            }
            // ── Download confirmation alert ─────────────────────────────────
            .alert(
                "Download \(downloadTarget?.displayName ?? "")?",
                isPresented: Binding(
                    get: { downloadTarget != nil },
                    set: { if !$0 { downloadTarget = nil } }
                )
            ) {
                if let model = downloadTarget {
                    if hasSufficientSpace(for: model) {
                        let label = model.sizeBytes > 0 ? "Download \(model.sizeFormatted)" : "Download"
                        Button(label) {
                            if model.format == .mlx {
                                Task { await downloads.startMLXDownload(model) }
                            } else {
                                downloads.start(model)
                            }
                            downloadTarget = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { downloadTarget = nil }
                }
            } message: {
                if let model = downloadTarget {
                    if hasSufficientSpace(for: model) {
                        let suffix = model.format == .mlx
                            ? " Downloads continue in the background when the screen is off."
                            : ""
                        if model.sizeBytes > 0 {
                            Text("\(model.sizeFormatted) will be downloaded and stored on this device.\(suffix)")
                        } else {
                            Text("The model will be downloaded and stored on this device.\(suffix)")
                        }
                    } else {
                        let needed = ByteCountFormatter.string(fromByteCount: model.sizeBytes,  countStyle: .file)
                        let free   = ByteCountFormatter.string(fromByteCount: availableBytes,   countStyle: .file)
                        Text("Not enough storage. Need \(needed) but only \(free) available. Free up space and try again.")
                    }
                }
            }
            // ── Delete confirmation alert ───────────────────────────────────
            .alert(
                "Delete \(deleteTarget?.displayName ?? "")?",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                )
            ) {
                if let model = deleteTarget {
                    Button("Delete", role: .destructive) {
                        Task {
                            await downloads.deleteModel(model.id, runtime: runtime)
                            if settings.current.selectedModelID == model.id {
                                await settings.set(\.selectedModelID, to: nil)
                            }
                        }
                        deleteTarget = nil
                    }
                    Button("Cancel", role: .cancel) { deleteTarget = nil }
                }
            } message: {
                if let model = deleteTarget {
                    if runtime.activeModel?.id == model.id {
                        Text("This model is currently loaded. It will be unloaded and deleted from disk.")
                    } else {
                        Text("The model file will be removed from this device. You can re-download it later.")
                    }
                }
            }
        }
    }
}

// MARK: - ModelBrowserRow

private struct ModelBrowserRow: View {
    let item:             ModelBrowserItem
    let isRunningOnPhone: Bool
    let onDownload:       () -> Void
    let onCancel:         () -> Void
    let onLoad:           () -> Void
    let onUnload:         () -> Void
    let onCancelMLXLoad:  () -> Void
    let onDelete:         () -> Void
    let onInfo:           () -> Void

    private var model: LocalModel { item.model }

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            // ── Header ───────────────────────────────────────────────────────
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(HHTheme.headline)
                        backendBadge
                        if isRunningOnPhone && isIPadOnly {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(HHTheme.warning)
                                .imageScale(.small)
                        }
                        if model.isUserAdded {
                            Text("Custom")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(HHTheme.accent.opacity(0.15))
                                .foregroundStyle(HHTheme.accent)
                                .clipShape(Capsule())
                        }
                    }
                    modelSubtitle
                    if isRunningOnPhone && isIPadOnly {
                        Text("iPad-only — likely to OOM on iPhone")
                            .font(HHTheme.caption)
                            .foregroundStyle(HHTheme.warning)
                    }
                }
                Spacer()
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(HHTheme.textSecondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }

            // ── State controls ────────────────────────────────────────────
            stateControls
        }
        .padding(.vertical, 6)
    }

    // MARK: - Header sub-views

    private var isIPadOnly: Bool {
        !model.recommendedFor.contains(.iPhone)
    }

    private var backendBadge: some View {
        Text(model.backend.displayName)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeBg, in: Capsule())
            .foregroundStyle(badgeFg)
    }

    private var badgeFg: Color {
        guard model.isUsableInThisBuild else { return HHTheme.textSecondary }
        switch model.backend {
        case .mlx:      return HHTheme.accent
        case .llamaCpp: return HHTheme.textSecondary
        }
    }

    private var badgeBg: Color {
        guard model.isUsableInThisBuild else { return HHTheme.textSecondary.opacity(0.10) }
        switch model.backend {
        case .mlx:      return HHTheme.accent.opacity(0.15)
        case .llamaCpp: return HHTheme.textSecondary.opacity(0.12)
        }
    }

    @ViewBuilder
    private var modelSubtitle: some View {
        if model.isUserAdded {
            let host = model.downloadURL.host(percentEncoded: false) ?? "custom"
            Text("\(host) · \(model.contextLength) tokens")
                .font(HHTheme.footnote)
                .foregroundStyle(HHTheme.textSecondary)
        } else {
            Text("\(model.family) · \(model.parameterCount) · \(model.quantization) · \(model.sizeFormatted)")
                .font(HHTheme.footnote)
                .foregroundStyle(HHTheme.textSecondary)
            Text("Context: \(model.contextLength) tokens · \(model.license)")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        }
    }

    // MARK: - State controls

    @ViewBuilder
    private var stateControls: some View {
        if !model.isUsableInThisBuild, let reason = model.unavailableReason {
            // Backend not linked in this build — replace all affordances with a
            // single explanation so dead buttons never reach the user.
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.warning)
                .lineLimit(3)
        } else {
            stateControlsUsable
        }
    }

    @ViewBuilder
    private var stateControlsUsable: some View {
        switch item.status {

        // ── Not installed ───────────────────────────────────────────────────
        case .notInstalled:
            if model.format == .mlx, let progress = item.mlxLoadProgress {
                mlxProgressView(progress: progress)
            } else if model.format == .mlx {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Download") { onDownload() }
                        .buttonStyle(HHSecondaryButtonStyle())
                        .accessibilityIdentifier("mlx_download_button")
                    Text("Background transfer · \(model.sizeFormatted) · tap Load after")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                }
            } else {
                HStack(spacing: HHTheme.spaceS) {
                    Button(item.hasResumeData ? "Resume" : "Download", action: onDownload)
                        .buttonStyle(HHSecondaryButtonStyle())
                    if item.hasResumeData {
                        Label("Paused", systemImage: "pause.circle.fill")
                            .font(HHTheme.caption)
                            .foregroundStyle(HHTheme.warning)
                    }
                }
            }

        // ── Downloading ─────────────────────────────────────────────────────
        case .downloading(let progress, let phase):
            VStack(alignment: .leading, spacing: 6) {
                // Indeterminate when: still preparing, or chunked transfer
                // (no Content-Length header → progress stays at 0).
                let isIndeterminate = (phase == .preparing) ||
                                      (phase == .downloading && progress < 0.001)
                if isIndeterminate {
                    ProgressView().controlSize(.regular)
                } else {
                    ProgressView(value: progress).tint(HHTheme.accent)
                }
                HStack {
                    downloadPhaseLabel(progress: progress, phase: phase,
                                       indeterminate: isIndeterminate)
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .font(HHTheme.subheadline)
                        .tint(HHTheme.danger)
                }
            }

        // ── Reconnecting ────────────────────────────────────────────────────
        case .reconnecting:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().controlSize(.regular)
                HStack {
                    Text("Reconnecting to background download…")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .font(HHTheme.subheadline)
                        .tint(HHTheme.danger)
                }
            }

        // ── Installed ───────────────────────────────────────────────────────
        case .installed:
            if model.format == .mlx, let progress = item.mlxLoadProgress {
                // Warm-cache load path: file is on disk, weights loading.
                mlxProgressView(progress: progress)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: HHTheme.spaceS) {
                        Button("Load", action: onLoad)
                            .buttonStyle(HHSecondaryButtonStyle())
                            .accessibilityIdentifier("mlx_load_button")
                        Spacer()
                        sizeLabel
                        deleteButton
                    }
                }
            }

        // ── Loading ─────────────────────────────────────────────────────────
        case .loading:
            if let progress = item.mlxLoadProgress {
                mlxProgressView(progress: progress)
            } else {
                HStack(spacing: HHTheme.spaceS) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                    Spacer()
                    Button("Cancel") { onCancelMLXLoad() }
                        .font(HHTheme.subheadline)
                        .tint(HHTheme.danger)
                }
            }

        // ── Loaded ──────────────────────────────────────────────────────────
        case .loaded:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: HHTheme.spaceS) {
                    Button("Unload", action: onUnload)
                        .buttonStyle(HHSecondaryButtonStyle())
                        .accessibilityIdentifier("mlx_unload_button")
                    Label("Active", systemImage: "bolt.fill")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.success)
                    Spacer()
                    sizeLabel
                    deleteButton
                }
            }

        // ── Unloading ───────────────────────────────────────────────────────
        case .unloading:
            HStack(spacing: HHTheme.spaceS) {
                ProgressView().controlSize(.small)
                Text("Unloading…")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
            }

        // ── Download failed ─────────────────────────────────────────────────
        case .downloadFailed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.warning)
                    .lineLimit(3)
                HStack(spacing: HHTheme.spaceS) {
                    Button(model.format == .mlx ? "Retry" : (item.hasResumeData ? "Resume" : "Retry")) {
                        model.format == .mlx ? onLoad() : onDownload()
                    }
                    .buttonStyle(HHSecondaryButtonStyle())
                    deleteButton
                }
            }

        // ── Load failed ─────────────────────────────────────────────────────
        case .loadFailed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.warning)
                    .lineLimit(3)
                HStack(spacing: HHTheme.spaceS) {
                    Button("Retry", action: onLoad)
                        .buttonStyle(HHSecondaryButtonStyle())
                        .accessibilityIdentifier("mlx_retry_button")
                    Spacer()
                    sizeLabel
                    deleteButton
                }
            }
        }
    }

    // MARK: - Reusable sub-views

    /// Two-phase MLX progress view for loading (download + prepare).
    @ViewBuilder
    private func mlxProgressView(progress: MLXLoadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch progress.phase {
            case .downloading(let fraction):
                ProgressView(value: fraction).tint(HHTheme.accent)
                    .accessibilityIdentifier("mlx_progress_bar")
                HStack {
                    Text("Downloading model… \(Int(fraction * 100))%")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                        .accessibilityIdentifier("mlx_progress_label")
                    Spacer()
                    Button("Cancel") { onCancelMLXLoad() }
                        .font(HHTheme.subheadline)
                        .tint(HHTheme.danger)
                        .accessibilityIdentifier("mlx_cancel_button")
                }
            case .preparing:
                ProgressView().controlSize(.small)
                    .accessibilityIdentifier("mlx_preparing_indicator")
                Text("Preparing model…")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
                    .accessibilityIdentifier("mlx_preparing_label")
            }
        }
    }

    @ViewBuilder
    private func downloadPhaseLabel(
        progress: Double,
        phase: ModelDownloadService.DownloadPhase,
        indeterminate: Bool
    ) -> some View {
        switch phase {
        case .preparing:
            Text("Preparing…")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        case .downloading:
            Text(indeterminate ? "Downloading…" : "Downloading · \(Int(progress * 100))%")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        case .validating:
            Text("Validating…")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        case .installing:
            Text("Installing…")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var sizeLabel: some View {
        if model.sizeBytes > 0 {
            Text(model.sizeFormatted)
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
                .foregroundStyle(HHTheme.danger)
                .imageScale(.medium)
        }
        .buttonStyle(.plain)
    }
}
