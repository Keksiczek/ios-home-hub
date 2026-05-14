import SwiftUI

/// Detailed info sheet for a single model — shown when the user taps
/// the info button in the model list.
///
/// Shows two categories of data:
/// - **Static metadata** (identity, requirements, source) from the catalog snapshot.
/// - **Live status** (download progress, runtime state, failure reasons) from
///   `ModelDownloadService` and `RuntimeManager` via `@EnvironmentObject`.
struct ModelInfoSheet: View {
    let model: LocalModel

    @EnvironmentObject private var downloads: ModelDownloadService
    @EnvironmentObject private var runtime:   RuntimeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // ── Live status ──────────────────────────────────────────────
                Section("Status") {
                    statusRows
                }

                // ── Runtime ──────────────────────────────────────────────────
                Section("Runtime") {
                    row("Backend", model.backend.displayName)
                    row("Format",  model.format.rawValue)
                    if !model.isUsableInThisBuild, let reason = model.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(model.backend.taglineCZ)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // ── Identity ─────────────────────────────────────────────────
                Section("Identity") {
                    row("Family",       model.family)
                    row("Parameters",   model.parameterCount)
                    row("Quantization", model.quantization)
                }

                // ── Requirements ─────────────────────────────────────────────
                Section("Requirements") {
                    row("File size",    model.sizeFormatted)
                    row("RAM estimate", estimatedRAM)
                    row("Context",      "\(model.contextLength) tokens")
                }

                // ── Source ───────────────────────────────────────────────────
                Section("Source") {
                    row("License", model.license)
                    row("Host",    downloadHost)
                }

                // ── Supported devices ─────────────────────────────────────────
                Section("Supported devices") {
                    ForEach(model.recommendedFor, id: \.self) { device in
                        row(nil, deviceLabel(device))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(model.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Live status rows

    @ViewBuilder
    private var statusRows: some View {
        // ── Download state ───────────────────────────────────────────────────
        let ds = downloads.active[model.id]
        switch model.installState {

        case .notInstalled:
            LabeledContent("Install state") {
                Text("Not installed")
                    .foregroundStyle(.secondary)
            }

        case .downloading(let progress):
            if DownloadManager.shared.isActive(model.id) && ds == nil {
                // Background task survived an OS kill; reconnecting.
                LabeledContent("Download") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Reconnecting…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let ds {
                LabeledContent("Download") {
                    Text(downloadPhaseDescription(ds.phase, progress: progress))
                        .foregroundStyle(.secondary)
                }
                if ds.phase == .downloading && progress >= 0.001 {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                        .listRowSeparator(.hidden)
                }
            } else {
                LabeledContent("Download") {
                    Text("Starting…")
                        .foregroundStyle(.secondary)
                }
            }

        case .installed(let localURL):
            LabeledContent("Install state") {
                Text("Installed")
                    .foregroundStyle(.green)
            }
            row("Local file", localURL.lastPathComponent)

        case .loaded(let localURL):
            LabeledContent("Install state") {
                Text("Installed")
                    .foregroundStyle(.green)
            }
            row("Local file", localURL.lastPathComponent)

        case .failed(let reason):
            LabeledContent("Download") {
                Text("Failed")
                    .foregroundStyle(.orange)
            }
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }

        // ── Runtime state ────────────────────────────────────────────────────
        switch runtime.state {
        case .idle:
            if runtime.activeModel?.id == model.id {
                LabeledContent("Runtime") {
                    Text("Active")
                        .foregroundStyle(.green)
                }
            }

        case .loading(let id) where id == model.id:
            LabeledContent("Runtime") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            }
            if let p = runtime.mlxLoadProgress, p.modelID == model.id {
                switch p.phase {
                case .downloading(let fraction):
                    ProgressView(value: fraction).tint(.accentColor)
                        .listRowSeparator(.hidden)
                case .preparing:
                    EmptyView()
                }
            }

        case .ready(let id) where id == model.id:
            LabeledContent("Runtime") {
                Text("Active")
                    .foregroundStyle(.green)
            }

        case .unloading:
            if runtime.activeModel?.id == model.id {
                LabeledContent("Runtime") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Unloading…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .failed(let failedID, let reason) where failedID == model.id:
            LabeledContent("Runtime") {
                Text("Load failed")
                    .foregroundStyle(.orange)
            }
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)

        default:
            EmptyView()
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ label: String?, _ value: String) -> some View {
        if let label {
            LabeledContent(label, value: value)
        } else {
            Text(value)
        }
    }

    private func downloadPhaseDescription(
        _ phase: ModelDownloadService.DownloadPhase,
        progress: Double
    ) -> String {
        switch phase {
        case .preparing:   return "Preparing…"
        case .downloading: return progress >= 0.001 ? "Downloading \(Int(progress * 100))%" : "Downloading…"
        case .validating:  return "Validating…"
        case .installing:  return "Installing…"
        }
    }

    /// Rough RAM estimate: file size + 1.5 GB overhead for KV cache and
    /// runtime temporaries. Errs on the high side.
    private var estimatedRAM: String {
        let overhead: Int64 = 1_500_000_000
        let total = model.sizeBytes + overhead
        return "≥ " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var downloadHost: String {
        model.downloadURL.host(percentEncoded: false) ?? "huggingface.co"
    }

    private func deviceLabel(_ device: DeviceClass) -> String {
        switch device {
        case .iPhone:      return "iPhone (8 GB RAM recommended)"
        case .iPadMSeries: return "iPad M-series"
        }
    }
}
