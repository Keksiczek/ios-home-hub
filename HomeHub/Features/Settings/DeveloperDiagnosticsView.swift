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
    @EnvironmentObject private var prompts: PromptAssemblyService

    @State private var stubModelIDs: [String] = []
    @State private var isScanning = false
    @State private var isResetting = false
    @State private var telemetryLog: [String] = []

    var body: some View {
        List {
            runtimeSection
            buildSection
            activeModelSection
            deviceEventsSection
            tokenBudgetSection
            integritySection
            actionsSection
            smokeTestSection
        }
        .navigationTitle("Developer Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await scanForStubs() }
        .task { await subscribeTelemetry() }
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
        Section("Build Configuration") {
            LabeledContent("C++ Bridge", value: cppBridgeLabel)
            LabeledContent("Download Mode", value: downloadModeLabel)
            LabeledContent("Device", value: deviceLabel)

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

    // MARK: - Token budget

    private var tokenBudgetSection: some View {
        Section {
            if let report = prompts.lastReport {
                LabeledContent("Mode",   value: report.mode.rawValue)
                LabeledContent("Family", value: report.family.isEmpty ? "default" : report.family)
                ForEach(report.sections, id: \.name) { section in
                    LabeledContent(section.name, value: "\(section.tokens) tokens")
                }
                LabeledContent("History kept",    value: "\(report.historyMessagesKept) msgs")
                LabeledContent("History dropped", value: "\(report.historyMessagesDropped) msgs")
                LabeledContent("Total prompt",    value: "\(report.totalPromptTokens) tokens")
                LabeledContent("Gen reserve",     value: "\(report.generationReserveTokens) tokens")
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

    // MARK: - File integrity

    private var integritySection: some View {
        Section {
            if isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning model files…").foregroundStyle(.secondary)
                }
            } else if stubModelIDs.isEmpty {
                Label("All installed files pass GGUF validation", systemImage: "checkmark.circle.fill")
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
            Text("File Integrity")
        } footer: {
            Text(
                "Valid GGUF files start with magic 0x47475546 and are ≥ 1 MB. " +
                "Dev-mode stubs (\"STUB_MODEL\", 10 bytes) are flagged here and will " +
                "be rejected by the runtime before they reach the C++ bridge."
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
        case .loading(let id):    return "Loading: \(id)"
        case .ready(let id):      return "Ready: \(id)"
        case .failed:             return "Failed (see error below)"
        }
    }

    private var cppBridgeLabel: String { "llama.cpp" }

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
            let entry = telemetryEntry(for: event)
            telemetryLog.append(entry)
            if telemetryLog.count > 12 { telemetryLog.removeFirst() }
        }
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
        }
    }
}
