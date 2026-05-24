import SwiftUI
import UIKit

/// On-device diagnostics panel for real-runtime iPhone testing.
///
/// Shows everything you need to know without Xcode attached:
/// - Runtime identifier and C++ bridge status
/// - Current build mode (real vs stub)
/// - RuntimeManager state (idle / loading / ready / failed)
/// - Active model and any load error
/// - Memory warning count and last auto-unload event
/// - Live telemetry log (last 12 events)
/// - GGUF file integrity scan with stub detection
/// - Recommended iPhone smoke-test model + first-run checklist
/// - "Reset All Models" to purge stub files and start fresh
struct DeveloperDiagnosticsView: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var catalog: ModelCatalogService
    @EnvironmentObject private var downloads: ModelDownloadService
    @EnvironmentObject private var promptBudget: PromptBudgetReporter
    @EnvironmentObject private var settings: SettingsService
    @EnvironmentObject private var conversations: ConversationService

    @State private var stubModelIDs: [String] = []
    @State private var isScanning = false
    @State private var isResetting = false
    @State private var telemetryLog: [String] = []
    @State private var lastTTFTms: Int? = nil
    @State private var lastThroughput: Double? = nil
    @State private var lastDurationMs: Int? = nil
    @State private var diagnosticsCopied = false
    /// Snapshot of `OOMTelemetryService.recentBreadcrumbs(...)` rendered
    /// in `oomBreadcrumbsSection`. Loaded on `.onAppear` and refreshed
    /// when the user taps the section's reload button; we don't observe
    /// the underlying file because it changes from outside SwiftUI's
    /// graph (MetricKit background queue + load-pipeline async writers)
    /// and a Combine bridge would add weight for a diagnostics-only view.
    @State private var breadcrumbs: [OOMTelemetryService.Breadcrumb] = []

    var body: some View {
        List {
            runtimeSection
            buildSection
            hardwareSection
            catalogSection
            activeModelSection
            deviceEventsSection
            oomBreadcrumbsSection
            generationPerformanceSection
            tokenBudgetSection
            chatMemorySection
            integritySection
            actionsSection
            exportSection
            smokeTestSection
        }
        .navigationTitle("Diagnostika runtime")
        .navigationBarTitleDisplayMode(.inline)
        .task { await scanForStubs() }
        .task { await subscribeTelemetry() }
        .task { reloadBreadcrumbs() }
    }

    // MARK: - Runtime

    private var runtimeSection: some View {
        Section("Runtime") {
            LabeledContent("Identifier", value: runtime.runtime.identifier)
            LabeledContent("State", value: stateLabel)

            if case .failed(_, let reason) = runtime.state {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .listRowBackground(Color.red.opacity(0.06))
            }
        }
    }

    // MARK: - Build

    private var buildSection: some View {
        Section {
            LabeledContent("Primary runtime", value: "MLX")
            LabeledContent("Available backends", value: RuntimeBackendAvailability.summary)
            LabeledContent("Active runtime", value: runtime.runtime.identifier)
            LabeledContent("Download Mode", value: downloadModeLabel)
            LabeledContent("Device", value: deviceLabel)
            if !RuntimeBackendAvailability.llamaCppAvailable {
                Text("Pro načtení GGUF / llama.cpp modelu zapni HOMEHUB_LLAMA_RUNTIME a přidej llama.xcframework. Viz README → \"Optional: llama.cpp opt-in\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Build Configuration")
        }
    }

    // MARK: - Hardware

    /// Surfaces the SoC family, safe-mode state, and the memory-safety
    /// factor used by `RuntimeManager.memoryCheck`. This is the panel users
    /// (and field-debug sessions) check first when a load is rejected or
    /// generation behaves oddly on older hardware.
    private var hardwareSection: some View {
        let hw    = HardwareCapabilities.shared
        let mem   = DeviceMemoryProvider.shared.profile
        let cacheBytes = min(mem.mlxGPUCacheLimitBytes, hw.safeGPUCacheLimitBytes)
        let cacheMB = Int(cacheBytes / 1024 / 1024)
        let profile = settings.current.performanceProfile
        let factor  = RuntimeManager.memorySafetyFactor(for: profile)
        return Section {
            LabeledContent("SoC", value: hw.soc.label)
            LabeledContent("Machine ID", value: hw.machineIdentifier)
                .font(.caption.monospaced())
            LabeledContent(
                "Flash Attention",
                value: hw.flashAttentionEnabled ? "Enabled" : "Disabled (safe mode)"
            )
            LabeledContent("MLX GPU cache", value: "\(cacheMB) MB")
            LabeledContent("Performance profile", value: profile.label)
            LabeledContent(
                "Memory safety factor",
                value: String(format: "×%.2f", factor)
            )
            LabeledContent("Memory tier", value: mem.tier.label)
            if hw.safeAttentionMode {
                Label(
                    "Safe-mode is active for this SoC — Flash Attention disabled, GPU cache clamped. Correctness over speed.",
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            // Memory oracle: surfaces the verdict from the last preflight
            // so field debug sessions can correlate odd post-load behavior
            // with a tight-fit warning that proceeded under user opt-in.
            if let verdict = runtime.lastFeasibilityVerdict {
                LabeledContent("Last preflight", value: verdictLabel(verdict))
                    .foregroundStyle(verdictColor(verdict))
            }
        } header: {
            Text("Hardware & Safe Mode")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "Older A-series chips (A11–A14) have documented Metal SDPA " +
                    "regressions. The runtime falls back to safer paths automatically. " +
                    "Memory factor depends on the Performance profile chosen in " +
                    "Settings → Generation Engine; the next load will use this value."
                )
                // Tooltip-style microcopy for the verdict row. Kept in the
                // footer so it's discoverable without adding popovers.
                if runtime.lastFeasibilityVerdict != nil {
                    Text(
                        "Last preflight: snímek paměti při posledním pokusu o " +
                        "load, ne trvalý verdikt zařízení.  " +
                        "**Safe** — model + rezerva se vejdou.  " +
                        "**Risky** — vejde se model, ale ne plná rezerva — load proběhne, generování může selhat pod tlakem.  " +
                        "**Cannot load** — i samotné váhy překračují volnou paměť — load je zablokován."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Compact one-liner for the tri-state oracle verdict.
    private func verdictLabel(_ verdict: RuntimeManager.LoadFeasibility) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        switch verdict {
        case .safe(let headroom):
            return "Safe (+\(fmt.string(fromByteCount: headroom)))"
        case .risky(let required, let available):
            return "Risky (need \(fmt.string(fromByteCount: required)), have \(fmt.string(fromByteCount: available)))"
        case .cannotLoad(let required, let available):
            return "Cannot load (need \(fmt.string(fromByteCount: required)), have \(fmt.string(fromByteCount: available)))"
        }
    }

    private func verdictColor(_ verdict: RuntimeManager.LoadFeasibility) -> Color {
        switch verdict {
        case .safe:       return .secondary
        case .risky:      return .orange
        case .cannotLoad: return .red
        }
    }

    // MARK: - Catalog

    private var catalogSection: some View {
        let mlx = catalog.models.filter { $0.backend == .mlx }.count
        let gguf = catalog.models.filter { $0.backend == .llamaCpp }.count
        let usable = catalog.usableModels.count
        let userAdded = catalog.models.filter(\.isUserAdded).count

        return Section {
            LabeledContent("MLX entries", value: "\(mlx)")
            LabeledContent("GGUF entries", value: "\(gguf)")
            LabeledContent("Usable in this build", value: "\(usable) / \(catalog.models.count)")
            if userAdded > 0 {
                LabeledContent("User-added", value: "\(userAdded)")
            }
            if usable < catalog.models.count {
                Text("\(catalog.models.count - usable) entries gated by missing build flag — see \"Available backends\" above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Catalog")
        }
    }

    // MARK: - Active model

    private var activeModelSection: some View {
        Section("Active Model") {
            if let model = runtime.activeModel {
                LabeledContent("ID", value: model.id)
                    .font(.caption.monospaced())
                LabeledContent("Name", value: model.displayName)
                LabeledContent("Size", value: formattedBytes(model.sizeBytes))
                LabeledContent("Context", value: "\(model.contextLength) tokens")

                if catalog.isIPadOnly(model) && isRunningOnPhone {
                    Label("iPad-only model on iPhone — OOM risk is high", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("No model loaded")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Device events

    private var deviceEventsSection: some View {
        Section {
            LabeledContent("Memory warnings", value: "\(container.memoryWarningCount)")
            // Background-completion counter — verifies the iOS
            // background-task assertion is actually buying us the
            // promised ~30 s of extra runtime when the user switches
            // apps mid-generation. Zero here while users report
            // truncated replies = a real lifecycle bug; nonzero =
            // working as designed.
            LabeledContent("BG completions", value: "\(container.backgroundGenerationCompletions)")

            if let note = container.lastUnloadNotification {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last auto-unload")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            if let pressure = container.lastPressureEvent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last pressure event")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatPressureSnapshot(pressure))
                        .font(.caption.monospaced())
                        .foregroundStyle(pressure.escalatedToHard ? .orange : .secondary)
                        .textSelection(.enabled)
                }
            }

            if container.pressureHistory.count > 1 {
                // The first entry duplicates `lastPressureEvent` above —
                // skip it so the disclosure doesn't show the same line
                // twice. Aggregates surface the *pattern*: "8× soft,
                // 1× hard, 0× deferred in the last 20 events" — that's
                // what answers "is the policy actually working?".
                DisclosureGroup {
                    let agg = aggregatePressure(container.pressureHistory)
                    Text("Tiers: SOFT \(agg.soft) · HARD \(agg.hard) · deferred \(agg.deferred)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    ForEach(Array(container.pressureHistory.enumerated()), id: \.offset) { _, ev in
                        Text(formatPressureSnapshot(ev))
                            .font(.caption2.monospaced())
                            .foregroundStyle(ev.escalatedToHard ? .orange : .secondary)
                            .textSelection(.enabled)
                    }
                    Button("Vymazat historii", role: .destructive) {
                        container.clearPressureHistory()
                    }
                    .font(.caption)
                } label: {
                    Text("Pressure history (\(container.pressureHistory.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !telemetryLog.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent telemetry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(telemetryLog, id: \.self) { entry in
                        Text(entry)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Device Events")
        } footer: {
            Text(
                "Memory warnings trigger automatic model unload per the runtime unload policy. " +
                "The model reloads when the app returns to foreground."
            )
        }
    }

    // MARK: - OOM breadcrumb log

    private var oomBreadcrumbsSection: some View {
        Section {
            if breadcrumbs.isEmpty {
                Text("Žádné události — zatím nikdo nezapsal breadcrumb. Po prvním loadu modelu se sem promítnou `mlx.load.*` landmarky.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                let summary = aggregateBreadcrumbs(breadcrumbs)
                LabeledContent("Záznamů zobrazeno", value: "\(breadcrumbs.count)")
                LabeledContent("Refused (OOM / mmap)", value: "\(summary.refusals)")
                LabeledContent("MetricKit payloady", value: "\(summary.metrickit)")
                if let last = breadcrumbs.first {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last landmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatBreadcrumb(last))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                DisclosureGroup {
                    // Show up to 50 newest entries inside the disclosure
                    // so the section header stays short. The breadcrumb
                    // file caps at 200 entries on disk; the in-memory
                    // snapshot is bounded by the `recentBreadcrumbs`
                    // limit (50) at load time.
                    ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { _, crumb in
                        Text(formatBreadcrumb(crumb))
                            .font(.caption2.monospaced())
                            .foregroundStyle(crumb.kind.hasPrefix("mlx.load.refused") ? .orange : .secondary)
                            .textSelection(.enabled)
                    }
                } label: {
                    Text("Posledních \(breadcrumbs.count) událostí")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    reloadBreadcrumbs()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }

                Spacer()

                // Share the raw JSON file so the user can attach it to
                // a bug report. ShareLink takes the URL directly —
                // iOS renders the right share sheet (Mail, AirDrop, …).
                // The file may not exist before the first breadcrumb
                // is written; guard so the button doesn't crash on a
                // fresh install.
                if FileManager.default.fileExists(atPath: OOMTelemetryService.shared.breadcrumbsFileURL.path) {
                    ShareLink(
                        item: OOMTelemetryService.shared.breadcrumbsFileURL,
                        preview: SharePreview("oom-breadcrumbs.json")
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .font(.caption)

            Button("Smazat log", role: .destructive) {
                OOMTelemetryService.shared.clear()
                reloadBreadcrumbs()
            }
            .font(.caption)
        } header: {
            Text("OOM breadcrumb log")
        } footer: {
            Text(
                "Strukturovaný log paměťových landmarků: `mlx.load.start` → `weightsMapped` → `prewarmDone`, " +
                "plus refusal events (per-shard / OOM gate) a `metrickit.*` payloady od OS (chodí ~jednou za 24 h). " +
                "Po jetsamu nech aplikaci restartovat a podívej se sem — poslední záznam před killem ukáže, " +
                "kde to spadlo. Share posílá samotný JSON soubor, žádný obsah konverzací."
            )
        }
    }

    // MARK: - Generation performance

    private var generationPerformanceSection: some View {
        Section {
            if let ttft = lastTTFTms {
                LabeledContent("Last TTFT", value: "\(ttft) ms")
            } else {
                Text("No generation yet — send a message to populate.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            if let tps = lastThroughput {
                LabeledContent("Throughput (last)", value: String(format: "%.1f t/s", tps))
            }
            if let dur = lastDurationMs {
                LabeledContent("Total duration", value: "\(dur) ms")
            }
            // Rolling average for the currently-active model — survives
            // single-generation noise that the "last TTFT / throughput"
            // row above is susceptible to.
            if let modelID = runtime.activeModel?.id,
               let avg = runtime.averageThroughput(for: modelID) {
                LabeledContent(
                    "Throughput (avg, n=\(avg.samples))",
                    value: String(format: "%.1f t/s", avg.tps)
                )
            }
            // Distribution view (p50/p95) — the tail is the honest
            // measure of how the model feels under sustained use. A
            // p95 that's < 30% of p50 means the model is stalling
            // periodically; debugging starts with thermal throttling
            // or KV-cache pressure before optimisation efforts.
            if let modelID = runtime.activeModel?.id,
               let pct = runtime.throughputPercentiles(for: modelID) {
                LabeledContent(
                    "Throughput (p50 / p95)",
                    value: String(format: "%.1f / %.1f t/s", pct.p50, pct.p95)
                )
            }
            // First-token latency (prefill cost). Independent of
            // throughput — a model can be slow-to-first-token but
            // then decode fast, or vice versa. Captures the wait
            // users actually feel between "Send" and the first
            // character appearing.
            if let modelID = runtime.activeModel?.id,
               let ttft = runtime.firstTokenLatencyPercentiles(for: modelID) {
                LabeledContent(
                    "Time-to-first-token (p50 / p95)",
                    value: "\(ttft.p50Ms) / \(ttft.p95Ms) ms"
                )
            }
            // Most recent user-facing failure, if any. Surfaced here as
            // well as on the Model Info sheet so power users debugging
            // multi-turn issues don't have to leave Settings.
            if let failure = runtime.lastGenerationError {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last failure")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(failure.backend) · \(failure.modelID)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Generation Performance")
        } footer: {
            Text(
                "TTFT (time-to-first-token) measures prompt evaluation latency. " +
                "Target: < 4 s on iPhone 15 Pro for a 500-token prompt. " +
                "Throughput reflects decode speed after the first token. " +
                "Average is a Welford-style rolling mean over completed generations."
            )
        }
    }

    // MARK: - Token budget

    private var tokenBudgetSection: some View {
        Section {
            if let report = promptBudget.lastReport {
                LabeledContent("Mode",   value: report.mode.rawValue)
                LabeledContent("Family", value: report.family.isEmpty ? "default" : report.family)
                ForEach(report.sections, id: \.name) { section in
                    LabeledContent(section.name, value: "\(section.tokens) tokens")
                }
                LabeledContent("History kept",    value: "\(report.historyMessagesKept) msgs")
                LabeledContent("History dropped", value: "\(report.historyMessagesDropped) msgs")
                LabeledContent("Total prompt",    value: "\(report.totalPromptTokens) tokens")
                LabeledContent("Gen reserve",     value: "\(report.generationReserveTokens) tokens")
                // Real-tokenizer ground truth + drift, when an MLX
                // tokenizer was available at the time the prompt was
                // sent. A persistent drift > ±15 % suggests the
                // family's `messageTokenOverhead` calibration is off.
                if let real = promptBudget.lastRealTokenCount {
                    LabeledContent("Real (BPE)", value: "\(real) tokens")
                    if let drift = promptBudget.heuristicDriftPercent {
                        let sign = drift >= 0 ? "+" : ""
                        LabeledContent("Heuristic drift") {
                            Text("\(sign)\(String(format: "%.1f", drift)) %")
                                .foregroundStyle(abs(drift) > 15 ? .orange : .secondary)
                        }
                    }
                }
            } else {
                Text("No prompt built yet — send a message to populate.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } header: {
            Text("Last Prompt Budget")
        } footer: {
            Text("Token counts use the heuristic estimator (±15% vs. real BPE). Reflects the most recent call to PromptAssemblyService.build().")
        }
    }

    // MARK: - Chat memory

    /// Live snapshot of the chat-memory subsystem (summaries, recall,
    /// prefetch). Surfaces the auto-summarizer's health and the
    /// per-conversation cache footprint so the user doesn't have to
    /// guess whether "the model forgot earlier turns" is a missing
    /// summary, a stuck task, or genuinely-out-of-budget context.
    private var chatMemorySection: some View {
        let snap = conversations.chatMemorySnapshot()
        return Section {
            LabeledContent("Conversations (total / cached)",
                           value: "\(snap.totalConversations) / \(snap.cachedConversations)")
            LabeledContent("Summaries cached", value: "\(snap.summariesCached)")
            if snap.summariesInProgress > 0 {
                LabeledContent("Summarizing now") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("\(snap.summariesInProgress)")
                    }
                }
            }
            if snap.prefetchesInProgress > 0 {
                LabeledContent("Retrieval prefetches", value: "\(snap.prefetchesInProgress)")
            }
            if let when = snap.mostRecentSummaryAt {
                LabeledContent("Last summary at",
                               value: DateFormatter.localizedString(from: when, dateStyle: .none, timeStyle: .medium))
            } else {
                Text("No summaries generated yet — short conversations don't need them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Chat Memory")
        } footer: {
            Text("Auto-summarizer condenses older messages when the history budget exceeds 70%. Cached summaries are kept in-memory; cleared on app relaunch. Prefetches warm the embedding cache as you type.")
        }
    }

    // MARK: - File integrity

    private var integritySection: some View {
        Section {
            if isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning model files…").foregroundStyle(.secondary)
                }
            } else if stubModelIDs.isEmpty {
                Label("All installed GGUF files pass validation", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(stubModelIDs, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Stub / invalid GGUF", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption.bold())
                        Text(id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("GGUF File Integrity")
        } footer: {
            Text(
                "Only GGUF / llama.cpp models are checked here — MLX models live in " +
                "the Hugging Face cache and are validated by the MLX loader at load time. " +
                "Valid GGUF files start with magic 0x47475546 and are ≥ 1 MB. " +
                "Dev-mode stubs (\"STUB_MODEL\", 10 bytes) are flagged here and will be " +
                "rejected by the runtime before they reach the C++ bridge."
            )
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            Button {
                Task { await scanForStubs() }
            } label: {
                Label("Re-scan Model Files", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning || isResetting)

            Button(role: .destructive) {
                Task { await resetModels() }
            } label: {
                if isResetting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Resetting…")
                    }
                } else {
                    Label("Reset All Models", systemImage: "trash")
                }
            }
            .disabled(isScanning || isResetting)
        } header: {
            Text("Actions")
        } footer: {
            Text(
                "Reset cancels active downloads, deletes all .gguf files from disk, " +
                "and resets every catalog entry to \"Not installed\". " +
                "Use this after switching from mock to real builds to remove stub files."
            )
        }
    }

    // MARK: - Export

    /// Diagnostic export — gives you a single shareable JSON blob that
    /// captures the same fields the rest of this screen renders.
    /// Bug-report friendly: paste it into an issue and the reader has
    /// the full runtime / settings context without having to ask back
    /// twenty questions.
    private var exportSection: some View {
        Section {
            Button {
                copyDiagnostics()
            } label: {
                Label(
                    diagnosticsCopied ? "Copied to clipboard" : "Copy diagnostics JSON",
                    systemImage: diagnosticsCopied ? "checkmark" : "doc.on.doc"
                )
                .foregroundStyle(diagnosticsCopied ? HHTheme.success : .primary)
                .animation(.easeInOut(duration: 0.15), value: diagnosticsCopied)
            }

            ShareLink(
                item: buildReport().jsonString(),
                preview: SharePreview("HomeHub diagnostics")
            ) {
                Label("Share diagnostics JSON…", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Export")
        } footer: {
            Text(
                "Captures runtime state, settings (sampler params, model), " +
                "device info, last generation perf, and the recent telemetry " +
                "events. Conversation contents and memory facts are NEVER " +
                "included."
            )
        }
    }

    // MARK: - Smoke test

    private var smokeTestSection: some View {
        let model = catalog.iPhoneSmokeTestModel
        return Section {
            LabeledContent("Model", value: model.displayName)
            LabeledContent("Size", value: formattedBytes(model.sizeBytes))
            LabeledContent("Family", value: model.family)
            LabeledContent("ID") {
                Text(model.id)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("First-run checklist")
                    .font(.caption.bold())
                    .padding(.top, 2)
                smokeTestStep("1", "Models tab → tap \(model.displayName) → Download (Wi-Fi required, ~1.6 GB)")
                smokeTestStep("2", "Wait for download to complete (progress bar reaches 100%)")
                smokeTestStep("3", "Tap \"Load\" → Runtime State above should change to Ready")
                smokeTestStep("4", "Chat tab → send \"Hello\" → expect streamed tokens within ~4 s")
                smokeTestStep("5", "Check telemetry log: modelLoaded → generationStarted → firstToken → generationFinished")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Expected benchmarks (iPhone 15 Pro)")
                        .font(.caption.bold())
                        .padding(.top, 4)
                    Text("• Model load: < 8 s\n• TTFT: < 4 s\n• Throughput: ≥ 2 t/s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Recommended Smoke-Test Model (iPhone)")
        } footer: {
            Text(
                "Gemma 2 2B is the smallest model in the catalog that produces " +
                "coherent responses. Use it to validate the end-to-end real-runtime " +
                "pipeline before testing larger models."
            )
        }
    }

    private func smokeTestStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number + ".")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Computed labels

    private var stateLabel: String {
        switch runtime.state {
        case .idle:               return "Idle"
        case .unloading:          return "Unloading"
        case .loading(let id):    return "Loading: \(id)"
        case .ready(let id):      return "Ready: \(id)"
        case .failed:             return "Failed (see error below)"
        }
    }

    /// Single source: `RuntimeBackendAvailability.summary` so the
    /// diagnostics report and the diagnostics screen agree.
    private var cppBridgeLabel: String {
        RuntimeBackendAvailability.summary
    }

    private var downloadModeLabel: String { "URLSession background (real)" }

    private var deviceLabel: String {
        #if targetEnvironment(simulator)
        return "Simulator (\(UIDevice.current.model))"
        #else
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return "iPhone (\(UIDevice.current.model))"
        case .pad:   return "iPad (\(UIDevice.current.model))"
        default:     return UIDevice.current.model
        }
        #endif
    }

    private var isRunningOnPhone: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Maps a live `PressureEventSnapshot` into the Codable wire-format
    /// used by the diagnostic report. Centralized so the tier-string
    /// classification (`"soft" | "hard" | "deferred"`) stays in sync
    /// with the in-app aggregate counters that drive the same buckets.
    private func encodePressureSnapshot(
        _ ev: AppContainer.PressureEventSnapshot
    ) -> DiagnosticReport.PressureEvent {
        let tier: String = {
            if ev.escalatedToHard { return "hard" }
            if ev.wasGenerating   { return "deferred" }
            return "soft"
        }()
        return DiagnosticReport.PressureEvent(
            occurredAtUnix: ev.occurredAt.timeIntervalSince1970,
            availableBytes: ev.availableBytes,
            weightsBytes: ev.weightsBytes,
            inDebounceWindow: ev.inDebounceWindow,
            belowHardFloor: ev.belowHardFloor,
            wasGenerating: ev.wasGenerating,
            tier: tier
        )
    }

    /// Tally of how the two-tier policy handled the recent pressure
    /// events. Used by the Diagnostics disclosure to surface *trend*
    /// instead of one line: "is the policy mostly deciding SOFT (good),
    /// HARD (device is genuinely tight) or DEFERRED (chat is busy and
    /// we're piling up signals)?" Each event maps to exactly one bucket.
    private func aggregatePressure(
        _ events: [AppContainer.PressureEventSnapshot]
    ) -> (soft: Int, hard: Int, deferred: Int) {
        var soft = 0, hard = 0, deferred = 0
        for ev in events {
            if ev.escalatedToHard {
                hard += 1
            } else if ev.wasGenerating {
                deferred += 1
            } else {
                soft += 1
            }
        }
        return (soft, hard, deferred)
    }

    /// Compact one-line summary of a pressure event for the device-events
    /// section. Optimised for "did the policy do the right thing?" at a
    /// glance: tier, the two numeric inputs, and the relevant flags.
    private func formatPressureSnapshot(_ ev: AppContainer.PressureEventSnapshot) -> String {
        let time = DateFormatter.localizedString(from: ev.occurredAt, dateStyle: .none, timeStyle: .medium)
        let tier = ev.escalatedToHard ? "HARD unload" : (ev.wasGenerating ? "deferred (generating)" : "SOFT trim")
        let avail = ev.availableBytes.map { formattedBytes($0) } ?? "?"
        let weights = ev.weightsBytes > 0 ? formattedBytes(ev.weightsBytes) : "no model"
        var flags: [String] = []
        if ev.inDebounceWindow { flags.append("window") }
        if ev.belowHardFloor   { flags.append("floor") }
        let flagStr = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
        return "\(time) — \(tier) · avail=\(avail) · weights=\(weights)\(flagStr)"
    }

    // MARK: - Breadcrumb helpers

    /// Refresh the in-memory snapshot from the on-disk breadcrumb log.
    /// Cheap: the file caps at 200 entries and `recentBreadcrumbs(...)`
    /// only reads + reverses, no parsing of MetricKit payload sidecars.
    private func reloadBreadcrumbs() {
        breadcrumbs = OOMTelemetryService.shared.recentBreadcrumbs(limit: 50)
    }

    /// Counts by kind for the header summary. Refusals are the most
    /// actionable category — if `refusals > 0` the user is hitting
    /// the per-shard or OOM gate and should switch model.
    private func aggregateBreadcrumbs(
        _ crumbs: [OOMTelemetryService.Breadcrumb]
    ) -> (refusals: Int, metrickit: Int) {
        var refusals = 0
        var metrickit = 0
        for crumb in crumbs {
            if crumb.kind.hasPrefix("mlx.load.refused") { refusals += 1 }
            if crumb.kind.hasPrefix("metrickit.")        { metrickit += 1 }
        }
        return (refusals, metrickit)
    }

    /// Compact one-line render. Trims the ISO timestamp to HH:mm:ss so
    /// it fits comfortably in a List row, prepends the available-RAM
    /// stamp (the single most useful field when reading post-jetsam),
    /// then the kind tag, then any context kv pairs.
    private func formatBreadcrumb(_ crumb: OOMTelemetryService.Breadcrumb) -> String {
        // ISO8601: "2026-05-24T13:46:51.123+02:00" → take just the time.
        let time: String = {
            if let tRange = crumb.timestamp.range(of: "T"),
               crumb.timestamp.distance(from: tRange.upperBound, to: crumb.timestamp.endIndex) >= 8 {
                let from = tRange.upperBound
                let to = crumb.timestamp.index(from, offsetBy: 8)
                return String(crumb.timestamp[from..<to])
            }
            return crumb.timestamp
        }()
        let ctx: String = crumb.context
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = ctx.isEmpty ? "" : " · \(ctx)"
        let msg = crumb.message.isEmpty ? "" : " — \(crumb.message)"
        return "\(time) avail=\(crumb.availableMemoryMB)MB · \(crumb.kind)\(msg)\(suffix)"
    }

    // MARK: - Async tasks

    private func scanForStubs() async {
        isScanning = true
        defer { isScanning = false }
        var found: [String] = []
        for model in catalog.models {
            let isStub = await container.localModelService.isStubOrInvalidGGUF(model.id)
            if isStub { found.append(model.id) }
        }
        stubModelIDs = found
    }

    private func resetModels() async {
        isResetting = true
        defer { isResetting = false }
        await downloads.resetAllModels()
        runtime.clearState()
        await scanForStubs()
    }

    private func subscribeTelemetry() async {
        let (stream, id) = await runtime.telemetry.subscribe()
        defer { Task { await runtime.telemetry.unsubscribe(id: id) } }
        for await event in stream {
            // Capture per-generation metrics for the performance section.
            switch event {
            case .firstToken(_, let ms):
                lastTTFTms = ms
            case .generationFinished(_, let stats, _):
                lastThroughput = stats.tokensPerSecond
                lastDurationMs = stats.totalDurationMs
            default:
                break
            }
            let entry = telemetryEntry(for: event)
            telemetryLog.append(entry)
            if telemetryLog.count > 12 { telemetryLog.removeFirst() }
        }
    }

    // MARK: - Report builder

    /// Snapshots the current diagnostics-screen state into a Codable
    /// report. Assembled at action time (not eagerly) so the JSON
    /// reflects whatever the user is looking at when they tap.
    private func buildReport() -> DiagnosticReport {
        let s = settings.current

        let runtimeState: String
        var failureReason: String?
        switch runtime.state {
        case .idle:                       runtimeState = "idle"
        case .unloading:                  runtimeState = "unloading"
        case .loading(let id):            runtimeState = "loading: \(id)"
        case .ready(let id):              runtimeState = "ready: \(id)"
        case .failed(let id, let reason):
            // `id` is `String?` — `failed` is reachable both for an
            // explicit model load (id present) and for a cold-start
            // self-test that has no model yet. Spell out the missing
            // case so the interpolation isn't `Optional("…")`.
            runtimeState = "failed: \(id ?? "<no model>")"
            failureReason = reason
        }

        let active = runtime.activeModel.map {
            DiagnosticReport.ActiveModel(
                id: $0.id,
                displayName: $0.displayName,
                family: $0.family,
                parameterCount: $0.parameterCount,
                quantization: $0.quantization,
                sizeBytes: $0.sizeBytes,
                contextLength: $0.contextLength
            )
        }

        let installState: (LocalModel) -> String = { m in
            switch m.installState {
            case .notInstalled: return "notInstalled"
            case .downloading:  return "downloading"
            case .installed:    return "installed"
            case .loaded:       return "loaded"
            case .failed:       return "failed"
            }
        }
        let installCounts = catalog.models.reduce(into: (installed: 0, downloading: 0, failed: 0)) { acc, m in
            switch installState(m) {
            case "installed", "loaded": acc.installed += 1
            case "downloading":          acc.downloading += 1
            case "failed":               acc.failed += 1
            default: break
            }
        }

        let budget = promptBudget.lastReport.map {
            DiagnosticReport.Budget(
                family: $0.family,
                mode: $0.mode.rawValue,
                totalPromptTokens: $0.totalPromptTokens,
                historyKept: $0.historyMessagesKept,
                historyDropped: $0.historyMessagesDropped
            )
        }

        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"

        return DiagnosticReport(
            generatedAt: .now,
            appVersion: appVersion,
            device: .init(
                modelName: UIDevice.current.model,
                systemVersion: UIDevice.current.systemVersion,
                isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                isSimulator: isSimulatorBuild
            ),
            build: .init(
                cppBridge: cppBridgeLabel,
                downloadMode: downloadModeLabel,
                realRuntimeFlag: realRuntimeFlag,
                primaryBackend: ModelBackend.mlx.rawValue
            ),
            runtime: .init(
                identifier: runtime.runtime.identifier,
                state: runtimeState,
                failureReason: failureReason
            ),
            activeModel: active,
            lastGeneration: .init(
                ttftMs: lastTTFTms,
                tokensPerSecond: lastThroughput,
                totalDurationMs: lastDurationMs
            ),
            memory: {
                let history = container.pressureHistory
                let agg = aggregatePressure(history)
                return .init(
                    memoryWarningCount: container.memoryWarningCount,
                    lastUnloadNotification: container.lastUnloadNotification,
                    pressureTierCounts: .init(soft: agg.soft, hard: agg.hard, deferred: agg.deferred),
                    pressureHistory: history.map { encodePressureSnapshot($0) }
                )
            }(),
            settings: .init(
                temperature: s.temperature,
                topP: s.topP,
                topK: s.topK,
                minP: s.minP,
                repeatPenalty: s.repeatPenalty,
                repeatPenaltyLastN: s.repeatPenaltyLastN,
                maxResponseTokens: s.maxResponseTokens,
                answerLength: s.answerLength.rawValue,
                language: s.language.rawValue
            ),
            catalog: .init(
                total: catalog.models.count,
                installed: installCounts.installed,
                downloading: installCounts.downloading,
                failed: installCounts.failed,
                userAdded: catalog.models.filter(\.isUserAdded).count,
                mlxModels: catalog.models.filter { $0.backend == .mlx }.count,
                ggufModels: catalog.models.filter { $0.backend == .llamaCpp }.count,
                usableInThisBuild: catalog.usableModels.count
            ),
            lastBudget: budget,
            recentTelemetry: telemetryLog,
            guardrails: {
                let g = s.guardrailsConfig
                var layers: [String] = []
                if g.factsEnabled           { layers.append("facts") }
                if g.episodesEnabled        { layers.append("episodes") }
                if g.fileExcerptsEnabled    { layers.append("fileExcerpts") }
                if g.skillInstructionsEnabled { layers.append("skillInstructions") }
                let preset: String
                if g == .default        { preset = "default" }
                else if g == .unrestricted { preset = "unrestricted" }
                else                    { preset = "custom" }
                return DiagnosticReport.GuardrailsSnapshot(
                    hardRulesEnabled: g.hardRulesEnabled,
                    privacyGuardrailEnabled: g.privacyGuardrailEnabled,
                    enabledContextLayers: layers.sorted(),
                    activePreset: preset
                )
            }(),
            huggingFace: hfSnapshot()
        )
    }

    /// Snapshots HF token state for the diagnostic report. Never
    /// includes the token itself — only the boolean presence, the
    /// last successful-validation timestamp, and a coarse status
    /// label. Status priority (top wins): live status from
    /// `AppContainer.huggingFaceTokenStatus` > cached validation
    /// timestamp staleness > "valid (assumed)" if a token exists but
    /// no validation has ever been recorded.
    private func hfSnapshot() -> DiagnosticReport.HuggingFaceSnapshot {
        let hasToken = HFTokenStore.hasToken
        guard hasToken else { return .none }
        let lastVerified = HFTokenStore.lastVerification()
        let statusLabel: String = {
            if let live = container.huggingFaceTokenStatus {
                switch live {
                case .valid:        return "valid"
                case .invalid:      return "invalid"
                case .networkError: return "networkError"
                }
            }
            // No live status yet — fall back to age check.
            if let last = lastVerified,
               Date().timeIntervalSince(last.at) > (7 * 24 * 60 * 60) {
                return "stale"
            }
            return lastVerified == nil ? "unverified" : "valid"
        }()
        return DiagnosticReport.HuggingFaceSnapshot(
            hasToken: true,
            lastVerifiedAtUnix: lastVerified?.at.timeIntervalSince1970,
            status: statusLabel
        )
    }

    /// Pushes the JSON report onto the system pasteboard and flips the
    /// button label to confirm. Resets after 1.5 s so a follow-up tap
    /// produces fresh output.
    private func copyDiagnostics() {
        UIPasteboard.general.string = buildReport().jsonString()
        withAnimation(.easeInOut(duration: 0.15)) { diagnosticsCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.15)) { diagnosticsCopied = false }
        }
    }

    private var isSimulatorBuild: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Whether the build was compiled with the optional llama.cpp runtime
    /// linked in. The diagnostic field name stays as `realRuntimeFlag` for
    /// JSON-export compatibility with older diagnostic dumps.
    private var realRuntimeFlag: Bool {
        #if HOMEHUB_LLAMA_RUNTIME
        return true
        #else
        return false
        #endif
    }

    private func telemetryEntry(for event: RuntimeTelemetryEvent) -> String {
        let t = DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .medium)
        switch event {
        case .modelLoaded(let h, let ms):
            return "\(t) ✓ Loaded '\(h.displayName)' \(ms)ms"
        case .modelUnloaded(let h, let reason):
            return "\(t) ↓ Unloaded '\(h.displayName)' [\(reason)]"
        case .generationStarted:
            return "\(t) ▶ Generation started"
        case .firstToken(_, let ms):
            return "\(t) ⚡ First token \(ms)ms"
        case .generationFinished(_, let stats, _):
            return "\(t) ■ \(stats.tokensGenerated)t @ \(String(format: "%.1f", stats.tokensPerSecond))t/s (\(stats.totalDurationMs)ms)"
        case .generationCancelled:
            return "\(t) ✕ Cancelled"
        case .memoryPressureReceived:
            return "\(t) ⚠ Memory pressure"
        case .backgroundEventReceived:
            return "\(t) ⬇ App backgrounded"
        case .loaderCancelTimeout(let reason, let seconds):
            return "\(t) ⏱ Cancel timeout [\(reason)] @ \(String(format: "%.1f", seconds))s"
        }
    }
}
