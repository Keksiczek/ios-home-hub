import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var catalog: ModelCatalogService
    @EnvironmentObject private var downloads: ModelDownloadService
    @EnvironmentObject private var runtime: RuntimeManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(catalog.models) { model in
                        ModelRow(
                            model: model,
                            isLoaded: runtime.activeModel?.id == model.id,
                            isLoading: runtime.state == .loading(modelID: model.id),
                            onDownload: { downloads.start(model) },
                            onCancelDownload: { downloads.cancel(model.id) },
                            onLoad: { Task { await runtime.load(model) } },
                            onUnload: { Task { await runtime.unload() } }
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
        }
    }
}

private struct ModelRow: View {
    let model: LocalModel
    let isLoaded: Bool
    let isLoading: Bool
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    let onLoad: () -> Void
    let onUnload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
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

            switch model.installState {
            case .notInstalled:
                Button("Download", action: onDownload)
                    .buttonStyle(HHSecondaryButtonStyle())
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
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.warning)
            }
        }
        .padding(.vertical, 6)
    }
}
