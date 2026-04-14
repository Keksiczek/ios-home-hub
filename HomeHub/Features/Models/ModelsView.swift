import SwiftUI
import UIKit

struct ModelsView: View {
    @EnvironmentObject private var catalog: ModelCatalogService
    @EnvironmentObject private var downloads: ModelDownloadService
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var settings: SettingsService

    private var isRunningOnPhone: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    @State private var downloadTarget: LocalModel?
    @State private var infoTarget: LocalModel?
    @State private var deleteTarget: LocalModel?
    @State private var showAddFromURL = false

    private var availableBytes: Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage.map { Int64($0) } ?? 0
    }

    private func hasSufficientSpace(for model: LocalModel) -> Bool {
        guard model.sizeBytes > 0 else { return true }   // unknown size → assume ok
        return availableBytes >= Int64(Double(model.sizeBytes) * 1.1)
    }

    /// Returns a user-visible runtime load-failure reason for `model`, if the
    /// last `runtime.load(...)` attempt was for this model and failed. The UI
    /// uses this to show a short error label + Retry button underneath the
    /// Load button so load failures are never silent.
    private func loadFailureReason(for model: LocalModel) -> String? {
        if case .failed(let failedID, let reason) = runtime.state, failedID == model.id {
            return reason
        }
        return nil
    }

    // MARK: - Section splits

    private var localModels: [LocalModel] {
        catalog.models.filter {
            switch $0.installState {
            case .installed, .loaded, .downloading, .failed: return true
            case .notInstalled: return false
            }
        }
    }

    private var availableModels: [LocalModel] {
        catalog.models.filter {
            if case .notInstalled = $0.installState { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── LOCAL MODELS ────────────────────────────────────────────
                if !localModels.isEmpty {
                    Section {
                        ForEach(localModels) { model in
                            ModelRow(
                                model: model,
                                downloadPhase: downloads.active[model.id]?.phase,
                                isLoaded: runtime.activeModel?.id == model.id,
                                isLoading: runtime.state == .loading(modelID: model.id),
                                loadFailureReason: loadFailureReason(for: model),
                                hasResumeData: downloads.hasResumeData(for: model.id),
                                showIPadOnlyWarning: catalog.isIPadOnly(model) && isRunningOnPhone,
                                onDownload: { downloadTarget = model },
                                onCancelDownload: { downloads.cancel(model.id) },
                                onLoad: {
                                    Task {
                                        await runtime.load(model)
                                        await settings.set(\.selectedModelID, to: model.id)
                                    }
                                },
                                onUnload: { Task { await runtime.unload() } },
                                onDelete: { deleteTarget = model },
                                onInfo: { infoTarget = model }
                            )
                        }
                    } header: {
                        Text("On this device")
                    }
                }

                // ── AVAILABLE TO DOWNLOAD ───────────────────────────────────
                if !availableModels.isEmpty {
                    Section {
                        ForEach(availableModels) { model in
                            ModelRow(
                                model: model,
                                downloadPhase: nil,
                                isLoaded: false,
                                isLoading: false,
                                loadFailureReason: nil,
                                hasResumeData: downloads.hasResumeData(for: model.id),
                                showIPadOnlyWarning: catalog.isIPadOnly(model) && isRunningOnPhone,
                                onDownload: { downloadTarget = model },
                                onCancelDownload: { downloads.cancel(model.id) },
                                onLoad: { },
                                onUnload: { },
                                onDelete: { },
                                onInfo: { infoTarget = model }
                            )
                        }
                    } header: {
                        Text("Available to download")
                    } footer: {
                        Text("Models run entirely on this device. Sizes shown are compressed quantizations that fit in device RAM.")
                    }
                }

                // ── EMPTY STATE ─────────────────────────────────────────────
                if localModels.isEmpty && availableModels.isEmpty {
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
            .refreshable {
                await downloads.reconcileInstallStates()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarMenuButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddFromURL = true
                    } label: {
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
            // Download confirmation alert
            .alert(
                "Download \(downloadTarget?.displayName ?? "")?",
                isPresented: Binding(
                    get: { downloadTarget != nil },
                    set: { if !$0 { downloadTarget = nil } }
                )
            ) {
                if let model = downloadTarget {
                    if hasSufficientSpace(for: model) {
                        Button("Download \(model.sizeBytes > 0 ? model.sizeFormatted : "")") {
                            downloads.start(model)
                            downloadTarget = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { downloadTarget = nil }
                }
            } message: {
                if let model = downloadTarget {
                    if hasSufficientSpace(for: model) {
                        if model.sizeBytes > 0 {
                            Text("\(model.sizeFormatted) will be downloaded and stored on this device.")
                        } else {
                            Text("The file will be downloaded and stored on this device.")
                        }
                    } else {
                        let needed = ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)
                        let free   = ByteCountFormatter.string(fromByteCount: availableBytes,  countStyle: .file)
                        Text("Not enough storage. Need \(needed) but only \(free) available. Free up space and try again.")
                    }
                }
            }
            // Delete confirmation alert
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
                            // Clear selected model if it was this one.
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

// MARK: - ModelRow

private struct ModelRow: View {
    let model: LocalModel
    let downloadPhase: ModelDownloadService.DownloadPhase?
    let isLoaded: Bool
    let isLoading: Bool
    /// Non-nil when the most recent `runtime.load(_:)` attempt targeted this
    /// model and failed. Drives the inline error label + Retry button below
    /// the Load control so load failures are never silent.
    let loadFailureReason: String?
    let hasResumeData: Bool
    let showIPadOnlyWarning: Bool
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    let onLoad: () -> Void
    let onUnload: () -> Void
    let onDelete: () -> Void
    let onInfo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(HHTheme.headline)
                        if showIPadOnlyWarning {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(HHTheme.warning)
                                .imageScale(.small)
                                .help("Recommended for iPad M-series only. May exceed iPhone RAM.")
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
                    if showIPadOnlyWarning {
                        Text("iPad-only — likely to OOM on iPhone")
                            .font(HHTheme.caption)
                            .foregroundStyle(HHTheme.warning)
                    }
                }
                Spacer()
                HStack(spacing: 12) {
                    Button(action: onInfo) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(HHTheme.textSecondary)
                            .imageScale(.medium)
                    }
                    .buttonStyle(.plain)
                }
            }

            stateControls
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var modelSubtitle: some View {
        if model.isUserAdded {
            // For user models, show the URL host + context length
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

    @ViewBuilder
    private var stateControls: some View {
        switch model.installState {
        case .notInstalled:
            HStack(spacing: HHTheme.spaceS) {
                Button(hasResumeData ? "Resume" : "Download", action: onDownload)
                    .buttonStyle(HHSecondaryButtonStyle())
                if hasResumeData {
                    Label("Paused", systemImage: "pause.circle.fill")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.warning)
                }
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress).tint(HHTheme.accent)
                HStack {
                    progressLabel(progress: progress)
                    Spacer()
                    Button("Cancel", action: onCancelDownload)
                        .font(HHTheme.subheadline)
                        .tint(HHTheme.danger)
                }
            }

        case .installed:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: HHTheme.spaceS) {
                    Button(isLoaded ? "Unload" : (loadFailureReason != nil ? "Retry" : "Load")) {
                        isLoaded ? onUnload() : onLoad()
                    }
                    .buttonStyle(HHSecondaryButtonStyle())
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    installedMetadata
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(HHTheme.danger)
                            .imageScale(.medium)
                    }
                    .buttonStyle(.plain)
                }
                if let reason = loadFailureReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.warning)
                        .lineLimit(3)
                }
            }

        case .loaded:
            HStack(spacing: HHTheme.spaceS) {
                Button("Unload", action: onUnload)
                    .buttonStyle(HHSecondaryButtonStyle())
                Label("Active", systemImage: "bolt.fill")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.success)
                Spacer()
                installedMetadata
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(HHTheme.danger)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.warning)
                    .lineLimit(3)
                HStack(spacing: HHTheme.spaceS) {
                    Button(hasResumeData ? "Resume" : "Retry", action: onDownload)
                        .buttonStyle(HHSecondaryButtonStyle())
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(HHTheme.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func progressLabel(progress: Double) -> some View {
        let phase = downloadPhase ?? .downloading
        switch phase {
        case .preparing:
            Text("Preparing…")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        case .downloading:
            Text("Downloading · \(Int(progress * 100))%")
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
    private var installedMetadata: some View {
        // Show actual on-disk size (may differ from catalog estimate for user models)
        if model.sizeBytes > 0 {
            Text(model.sizeFormatted)
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.textSecondary)
        }
    }
}

