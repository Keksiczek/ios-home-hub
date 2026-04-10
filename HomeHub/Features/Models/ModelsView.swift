import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var catalog: ModelCatalogService
    @EnvironmentObject private var downloads: ModelDownloadService
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var settings: SettingsService

    /// Model pending download confirmation (shown in alert).
    @State private var downloadTarget: LocalModel?
    /// Model whose detail sheet is open.
    @State private var infoTarget: LocalModel?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(catalog.models) { model in
                        ModelRow(
                            model: model,
                            isLoaded: runtime.activeModel?.id == model.id,
                            isLoading: runtime.state == .loading(modelID: model.id),
                            hasResumeData: downloads.hasResumeData(for: model.id),
                            onDownload: { downloadTarget = model },
                            onCancelDownload: { downloads.cancel(model.id) },
                            onLoad: {
                                Task {
                                    await runtime.load(model)
                                    await settings.set(\.selectedModelID, to: model.id)
                                }
                            },
                            onUnload: { Task { await runtime.unload() } },
                            onInfo: { infoTarget = model }
                        )
                    }
                } header: {
                    Text("Curated")
                } footer: {
                    Text("Models run entirely on this device. Sizes shown are compressed quantizations that fit in device RAM.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Models")
            .sheet(item: $infoTarget) { model in
                ModelInfoSheet(model: model)
            }
            .alert(
                "Download \(downloadTarget?.displayName ?? "")?",
                isPresented: Binding(
                    get: { downloadTarget != nil },
                    set: { if !$0 { downloadTarget = nil } }
                )
            ) {
                if let model = downloadTarget {
                    Button("Download \(model.sizeFormatted)") {
                        downloads.start(model)
                        downloadTarget = nil
                    }
                    Button("Cancel", role: .cancel) { downloadTarget = nil }
                }
            } message: {
                if let model = downloadTarget {
                    Text("\(model.sizeFormatted) will be downloaded. The file will be stored on this device and uses device storage.")
                }
            }
        }
    }
}

private struct ModelRow: View {
    let model: LocalModel
    let isLoaded: Bool
    let isLoading: Bool
    let hasResumeData: Bool
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    let onLoad: () -> Void
    let onUnload: () -> Void
    let onInfo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(HHTheme.headline)
                    Text("\(model.family) · \(model.parameterCount) · \(model.quantization) · \(model.sizeFormatted)")
                        .font(HHTheme.footnote)
                        .foregroundStyle(HHTheme.textSecondary)
                    Text("Context: \(model.contextLength) tokens · \(model.license)")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                }
                Spacer()
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(HHTheme.textSecondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }

            switch model.installState {
            case .notInstalled:
                HStack(spacing: HHTheme.spaceS) {
                    Button("Download", action: onDownload)
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
                        Text("Downloading · \(Int(progress * 100))%")
                            .font(HHTheme.caption)
                            .foregroundStyle(HHTheme.textSecondary)
                        Spacer()
                        Button("Cancel", action: onCancelDownload)
                            .font(HHTheme.subheadline)
                            .tint(HHTheme.danger)
                    }
                }

            case .installed:
                HStack(spacing: HHTheme.spaceS) {
                    Button(isLoaded ? "Unload" : "Load") {
                        isLoaded ? onUnload() : onLoad()
                    }
                    .buttonStyle(HHSecondaryButtonStyle())
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                }

            case .loaded:
                Button("Unload", action: onUnload)
                    .buttonStyle(HHSecondaryButtonStyle())

            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.warning)
                    HStack(spacing: HHTheme.spaceS) {
                        Button("Retry", action: onDownload)
                            .buttonStyle(HHSecondaryButtonStyle())
                        if hasResumeData {
                            Label("Paused", systemImage: "pause.circle.fill")
                                .font(HHTheme.caption)
                                .foregroundStyle(HHTheme.warning)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
