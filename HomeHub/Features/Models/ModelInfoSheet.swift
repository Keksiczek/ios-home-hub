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
    @EnvironmentObject private var catalog:   ModelCatalogService
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
                    row("Safe mode", safeModeLabel)
                    if !model.isUsableInThisBuild, let reason = model.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(model.backend.taglineCZ)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Surface the most recent generation failure (if any
                    // and if it belongs to *this* model). Keeps the error
                    // visible without forcing the user back into chat.
                    if let failure = runtime.lastGenerationError,
                       failure.modelID == model.id {
                        Label(failure.message, systemImage: "exclamationmark.bubble.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                // ── Identity ─────────────────────────────────────────────────
                Section("Identity") {
                    row("Family",       model.family)
                    row("Parameters",   model.parameterCount)
                    row("Quantization", model.quantization)
                }

                // ── Model metadata (from GGUF header when available) ─────────
                modelMetadataSection

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

    // MARK: - Hardware cue

    /// Compact "ON (A14)" / "OFF" style label so the row reads at a
    /// glance. Pulls straight from `HardwareCapabilities` — that's the
    /// single source of truth for the safe-attention decision.
    private var safeModeLabel: String {
        let hw = HardwareCapabilities.shared
        return hw.safeAttentionMode ? "ON (\(hw.soc.label))" : "OFF"
    }

    // MARK: - Model metadata

    /// Surfaces the small subset of GGUF header fields we cache plus the
    /// resolved "what will the runtime actually use" values. MLX models
    /// don't go through this cache (their template comes from the
    /// tokenizer snapshot inside `MLXLLM.ChatSession`) so we render a
    /// dedicated note instead of pretending we have data.
    @ViewBuilder
    private var modelMetadataSection: some View {
        let meta = catalog.metadata(for: model.id)
        Section("Model metadata") {
            switch model.format {
            case .mlx:
                LabeledContent("Architecture", value: model.family)
                LabeledContent("Context window", value: "\(model.contextLength) tokens")
                LabeledContent("Template source", value: "Tokenizer snapshot (MLX)")
                Text("MLX models load their chat template from the tokenizer snapshot at load time. The runtime always uses the model's own template — no built-in fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .gguf:
                if let meta {
                    LabeledContent("Architecture", value: meta.architecture ?? "unknown")
                    LabeledContent("Context window", value: contextLabel(for: meta))
                    LabeledContent("Template source", value: templateSourceLabel(meta.templateSource))
                    if let metaName = meta.displayName, metaName != model.displayName {
                        LabeledContent("Embedded name", value: metaName)
                    }
                } else if case .notInstalled = model.installState {
                    Text("Metadata is read from the GGUF header after download.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Metadata is not available — either the GGUF header could not be parsed or the cache hasn't been populated yet. Re-installing the model rebuilds it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func contextLabel(for meta: GGUFModelMetadata) -> String {
        if let metaCtx = meta.contextLength {
            let effective = min(model.contextLength, metaCtx)
            if effective == metaCtx {
                return "\(effective) tokens (model native)"
            }
            return "\(effective) tokens (limited from \(metaCtx))"
        }
        return "\(model.contextLength) tokens (catalog)"
    }

    private func templateSourceLabel(_ source: GGUFModelMetadata.TemplateSource) -> String {
        switch source {
        case .gguf:    return "From GGUF metadata"
        case .builtIn: return "Built-in (family: \(model.family))"
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
