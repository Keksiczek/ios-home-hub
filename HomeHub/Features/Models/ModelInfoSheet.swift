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
    @EnvironmentObject private var settings:  SettingsService
    @Environment(\.dismiss) private var dismiss

    /// On-demand snapshot of the memory oracle's verdict for **this**
    /// model evaluated **right now**. Computed off-main on `.task`
    /// to avoid a blocking sysctl on view open and to stay honest about
    /// the "snapshot in time" nature of the verdict — see the footer
    /// note next to the verdict row for the user-facing version.
    @State private var liveVerdict: RuntimeManager.LoadFeasibility?
    @State private var isComputingVerdict = false

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

                // ── Memory estimate + oracle verdict ────────────────────────
                memoryEstimateSection

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
            .task(id: model.id) {
                await refreshLiveVerdict()
            }
        }
    }

    // MARK: - Memory estimate section

    /// Surfaces the three numbers users actually care about when
    /// deciding whether a model fits:
    ///   1. The model's intrinsic memory footprint (weights + KV cache).
    ///   2. The safety multiplier the active profile demands on top.
    ///   3. A snapshot oracle verdict for "right now on this device".
    ///
    /// All three are derived from pure helpers on `RuntimeManager`;
    /// no blocking work happens on view open beyond a single sysctl
    /// in a detached Task.
    @ViewBuilder
    private var memoryEstimateSection: some View {
        Section {
            // Memory footprint at the catalog-declared context length.
            let kvBytes = RuntimeManager.estimatedKVCacheBytes(for: model)
            let totalBytes = RuntimeManager.estimatedTotalMemoryBytes(for: model)
            LabeledContent(
                "Odhad paměti",
                value: "≈ \(byteString(totalBytes)) při \(contextLabel(model.contextLength)) kontextu"
            )
            // Break down KV cache separately so the user can see why a
            // long-context profile costs more than the raw weight file
            // would suggest.
            if kvBytes > 0 {
                LabeledContent(
                    "z toho KV cache",
                    value: "≈ \(byteString(kvBytes)) (\(model.contextLength) tokenů)"
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            // Profile multiplier — explains how the oracle decides
            // whether to gate.
            let profile = settings.current.performanceProfile
            let factor = RuntimeManager.memorySafetyFactor(for: profile)
            LabeledContent(
                "Bezpečná rezerva (\(profile.label))",
                value: String(format: "× %.2f → ≈ %@", factor, byteString(Int64(Double(totalBytes) * factor)))
            )

            // Verdict row — async snapshot. The placeholder text
            // covers (a) view just opened (computing) and (b) device
            // didn't return a usable available-memory number.
            verdictRow
        } header: {
            Text("Odhad paměti")
        } footer: {
            // Educate the user that this is a snapshot, not a permanent
            // property of the device — verdicts shift with whatever
            // other apps are doing.
            Text("Odhady jsou orientační. Verdikt je snímek paměti v okamžiku otevření tohoto detailu, ne trvalý výrok o zařízení — uvolnění paměti jinde (zavření safari, fotek …) může změnit `risky` na `safe`.")
        }
    }

    private var verdictRow: some View {
        // Compute label + color outside of @ViewBuilder context. Using a
        // tuple-returning helper keeps the SwiftUI body shape simple
        // (one expression) and avoids the `let` assignment / statement
        // pattern that @ViewBuilder can't fold into a view tree.
        let (label, color) = verdictCopy()
        return LabeledContent("Aktuální verdict") {
            HStack(spacing: 6) {
                if isComputingVerdict {
                    ProgressView().controlSize(.mini)
                }
                Text(label).foregroundStyle(color)
            }
        }
    }

    /// Maps the current oracle/loading state into a localised label
    /// + accent colour used by `verdictRow`. Pulled into its own
    /// function so the row body stays a single SwiftUI expression.
    private func verdictCopy() -> (String, Color) {
        if let verdict = liveVerdict {
            switch verdict {
            case .safe(let headroom):
                return ("Safe (rezerva ≈ \(byteString(headroom)))", .green)
            case .risky(let required, let available):
                return ("Risky — potřeba \(byteString(required)), volných \(byteString(available))", .orange)
            case .cannotLoad(let required, let available):
                return ("Cannot load — potřeba \(byteString(required)), volných \(byteString(available))", .red)
            }
        } else if isComputingVerdict {
            return ("Odhad paměti…", .secondary)
        } else {
            return ("Preflight zatím neproběhl", .secondary)
        }
    }

    /// Async re-evaluate the oracle for this model + active profile.
    /// Runs `evaluateFeasibility` off-main; the sysctl is fast but the
    /// detached Task documents intent and keeps the contract uniform
    /// with the production load gate. Idempotent — safe to call from
    /// `.task` which fires on every view appearance for the model ID.
    private func refreshLiveVerdict() async {
        isComputingVerdict = true
        let profileSnapshot = settings.current.performanceProfile
        let modelSnapshot = model
        let verdict = await Task.detached(priority: .userInitiated) {
            RuntimeManager.evaluateFeasibility(for: modelSnapshot, profile: profileSnapshot)
        }.value
        // Guard against the view dismissing while the Task was in flight.
        await MainActor.run {
            liveVerdict = verdict
            isComputingVerdict = false
        }
    }

    /// Common byte → "1.9 GB" / "190 MB" formatter so all rows in the
    /// estimate section render consistently.
    private func byteString(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    /// Compact "2k" / "4k" rendering of a token count. Falls back to
    /// the raw integer for non-round values.
    private func contextLabel(_ tokens: Int) -> String {
        if tokens >= 1000, tokens % 1024 == 0 {
            return "\(tokens / 1024)k"
        }
        return "\(tokens)"
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
