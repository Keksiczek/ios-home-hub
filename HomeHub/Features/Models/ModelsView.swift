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
    /// Coarse "this device looks comfortable for LLM work right now"
    /// signal. Recomputed off-main on appearance + pull-to-refresh. We
    /// keep `nil` until the first compute completes so the strip can
    /// show a placeholder instead of misleading "vysoká" before we've
    /// actually queried the system.
    @State private var memoryHeadroom: RuntimeManager.MemoryHeadroom?

    // MARK: - Disk stats

    private func refreshAvailableBytes() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v   = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        availableBytes = v?.volumeAvailableCapacityForImportantUsage.map { Int64($0) } ?? 0
    }

    /// Async refresh of the memory-headroom strip. Runs the sysctl off
    /// the main actor — fast in practice, but the detached Task keeps
    /// the contract uniform with the production load gate and makes
    /// the off-main intent explicit.
    private func refreshMemoryHeadroom() async {
        let profileSnapshot = settings.current.performanceProfile
        let result = await Task.detached(priority: .userInitiated) {
            RuntimeManager.currentHeadroom(profile: profileSnapshot)
        }.value
        await MainActor.run {
            memoryHeadroom = result
        }
    }

    private func hasSufficientSpace(for model: LocalModel) -> Bool {
        guard model.sizeBytes > 0 else { return true }
        return availableBytes >= Int64(Double(model.sizeBytes) * 1.1)
    }

    // MARK: - Memory headroom strip

    /// Compact "Paměťová rezerva pro LLM: vysoká/střední/nízká" row
    /// shown above the model list. Defensive against `nil` headroom
    /// (initial state before the first compute) — renders a quiet
    /// placeholder rather than guessing.
    @ViewBuilder
    private var memoryHeadroomRow: some View {
        let headroom = memoryHeadroom
        HStack(spacing: HHTheme.spaceS) {
            Image(systemName: headroomIcon(for: headroom))
                .foregroundStyle(headroomColor(for: headroom))
                .imageScale(.medium)
            VStack(alignment: .leading, spacing: 1) {
                Text("Paměťová rezerva pro LLM: \(headroomLabel(for: headroom))")
                    .font(HHTheme.footnote.weight(.medium))
                    .foregroundStyle(HHTheme.textPrimary)
                Text("Snímek paměti zařízení v této chvíli — uvolnění jiných aplikací může číslo zlepšit.")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(HHTheme.spaceM)
        .background(
            RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                .fill(headroomColor(for: headroom).opacity(0.10))
        )
    }

    private func headroomLabel(for h: RuntimeManager.MemoryHeadroom?) -> String {
        guard let h else { return "počítá se…" }
        return h.localizedLabel
    }

    private func headroomIcon(for h: RuntimeManager.MemoryHeadroom?) -> String {
        guard let h else { return "hourglass" }
        switch h {
        case .high:    return "memorychip"
        case .medium:  return "memorychip.fill"
        case .low:     return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func headroomColor(for h: RuntimeManager.MemoryHeadroom?) -> Color {
        guard let h else { return HHTheme.textSecondary }
        switch h {
        case .high:    return HHTheme.success
        case .medium:  return HHTheme.accent
        case .low:     return HHTheme.warning
        case .unknown: return HHTheme.textSecondary
        }
    }

    /// `true` for catalog entries recommended for iPad-only that the
    /// user is browsing on an iPhone. Maps to compatibility category 2
    /// (risky / experimental) — the download is **allowed** but the
    /// confirm sheet adds an explicit memory-risk warning so the user
    /// can opt in knowingly instead of getting a confusing failure on
    /// first load. This is intentionally NOT a download block: heavy
    /// models like Gemma 3n stay reachable as a baseline for users
    /// who want to experiment.
    private func isRiskyOnPhone(_ model: LocalModel) -> Bool {
        isRunningOnPhone && !model.recommendedFor.contains(.iPhone)
    }

    /// Compose the download confirm sheet's body text from the static
    /// recommendation plus a snapshot of the memory oracle's verdict for
    /// **this device, right now**, plus the coarse device-wide headroom.
    /// Three buckets blended:
    ///   - `cannotLoad` → strong "load se na toto zařízení nevejde"
    ///   - `risky` (or oracle unavailable) → "běh nejistý"; if headroom
    ///     is `low` we explicitly say "velmi pravděpodobně selže"
    ///   - `safe` (oracle says fits with margin) → mildest copy; if
    ///     headroom is `high` we drop the warning tone further
    private func downloadDialogRiskMessage(for model: LocalModel) -> String {
        let verdict = RuntimeManager.evaluateFeasibility(
            for: model,
            profile: settings.current.performanceProfile
        )
        let base = "\(model.sizeFormatted) – doporučeno pro iPad."
        let headroomTail: String = {
            switch memoryHeadroom {
            case .low?:    return " Vaše aktuální paměťová rezerva je nízká."
            case .high?:   return " Vaše aktuální paměťová rezerva je dostatečná."
            default:       return ""
            }
        }()
        switch verdict {
        case .cannotLoad?:
            return base
                + " V aktuálním stavu paměti by se model na toto zařízení nevešel."
                + headroomTail
                + " Stáhnout můžete, ale načtení skoro jistě selže."
        case .risky?, .none:
            if memoryHeadroom == .low {
                return base
                    + " Vaše aktuální paměťová rezerva je nízká — tento model velmi pravděpodobně selže při načtení nebo generování."
            }
            return base + " Stažení je možné, ale načtení nebo generování na tomto zařízení může selhat kvůli paměti." + headroomTail
        case .safe?:
            if memoryHeadroom == .high {
                return base + " Aktuálně by se model do paměti měl vejít, ale na iPhonu zůstává experimentální."
            }
            return base + " Aktuálně by se model do paměti měl vejít, ale na iPhonu zůstává experimentální." + headroomTail
        }
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

    /// Disk-space alert tier. Drives the banner shown above the model
    /// list — keeps the alert in the user's peripheral vision instead
    /// of waiting for them to tap Download and discover the problem in
    /// a modal. Thresholds picked so they correspond to common
    /// model sizes: 1 GB ≈ a typical 4-bit 1B-3B model, 500 MB ≈
    /// anything bigger will fail to install.
    private enum DiskAlertTier { case none, low, critical }
    private var diskAlertTier: DiskAlertTier {
        // availableBytes == 0 means the resource read hasn't fired yet
        // (first frame after launch). Suppress until we have real data
        // so we don't flash a phantom warning during the load.
        guard availableBytes > 0 else { return .none }
        if availableBytes < 500_000_000 { return .critical }
        if availableBytes < 1_500_000_000 { return .low }
        return .none
    }

    @ViewBuilder
    private var diskAlertBanner: some View {
        let tier = diskAlertTier
        if tier != .none {
            let free = ByteCountFormatter.string(fromByteCount: max(availableBytes, 0), countStyle: .file)
            HStack(spacing: HHTheme.spaceS) {
                Image(systemName: tier == .critical ? "externaldrive.badge.exclamationmark" : "externaldrive.badge.questionmark")
                    .foregroundStyle(tier == .critical ? HHTheme.danger : HHTheme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tier == .critical
                         ? "Critical: only \(free) free"
                         : "Low disk space — \(free) free")
                        .font(HHTheme.caption.weight(.semibold))
                        .foregroundStyle(HHTheme.textPrimary)
                    Text(tier == .critical
                         ? "Delete an unused model or free space in Settings → Storage before downloading."
                         : "Most models need 0.5–4 GB. Consider deleting an unused one before downloading more.")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HHTheme.spaceL)
            .padding(.vertical, HHTheme.spaceS)
            .background(
                RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                    .fill((tier == .critical ? HHTheme.danger : HHTheme.warning).opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                    .stroke((tier == .critical ? HHTheme.danger : HHTheme.warning).opacity(0.25), lineWidth: 0.5)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tier == .critical ? "Critical low disk space" : "Low disk space")
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                // Memory-headroom strip — always rendered (with placeholder
                // before the first compute) so the layout doesn't jump
                // when the result lands. Coarse three-bucket signal:
                // not real-time accuracy, just a "device feels …" reading.
                Section {
                    memoryHeadroomRow
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                .listSectionSpacing(.compact)

                // Ambient low-disk banner. Renders only when the alert
                // tier is non-`.none`, so the layout stays flat for
                // users with healthy storage. The banner uses the same
                // padding pattern as `memoryHeadroomRow` so the visual
                // rhythm is preserved.
                if diskAlertTier != .none {
                    Section {
                        diskAlertBanner
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
                    .listSectionSpacing(.compact)
                }

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
                await refreshMemoryHeadroom()
                await downloads.reconcileInstallStates()
            }
            .onAppear {
                // Connect the view-model once; idempotent on subsequent appearances.
                vm.connect(catalog: catalog, downloads: downloads, runtime: runtime)
                refreshAvailableBytes()
            }
            .task {
                // Headroom compute lives on `.task` (not `.onAppear`) so
                // the structured-concurrency cancellation behavior kicks
                // in if the user navigates away mid-compute. Idempotent
                // on re-appearance — re-runs whenever the view comes back.
                await refreshMemoryHeadroom()
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
                    if !hasSufficientSpace(for: model) {
                        // Disk space is a hard block — no Download action.
                        Button("Cancel", role: .cancel) { downloadTarget = nil }
                    } else if isRiskyOnPhone(model) {
                        // Soft gate: download proceeds, but the action label
                        // ("Stáhnout přesto") signals the user is opting in
                        // to a non-guaranteed run.
                        Button("Stáhnout přesto") {
                            if model.format == .mlx {
                                Task { await downloads.startMLXDownload(model) }
                            } else {
                                downloads.start(model)
                            }
                            downloadTarget = nil
                        }
                        Button("Zrušit", role: .cancel) { downloadTarget = nil }
                    } else {
                        let label = model.sizeBytes > 0 ? "Download \(model.sizeFormatted)" : "Download"
                        Button(label) {
                            if model.format == .mlx {
                                Task { await downloads.startMLXDownload(model) }
                            } else {
                                downloads.start(model)
                            }
                            downloadTarget = nil
                        }
                        Button("Cancel", role: .cancel) { downloadTarget = nil }
                    }
                }
            } message: {
                if let model = downloadTarget {
                    if !hasSufficientSpace(for: model) {
                        let needed = ByteCountFormatter.string(fromByteCount: model.sizeBytes,  countStyle: .file)
                        let free   = ByteCountFormatter.string(fromByteCount: availableBytes,   countStyle: .file)
                        Text("Not enough storage. Need \(needed) but only \(free) available. Free up space and try again.")
                    } else if isRiskyOnPhone(model) {
                        // Static catalog + dynamic oracle both inform this
                        // text. The static side (iPad-recommended on iPhone)
                        // anchors the wording; if the dynamic oracle says
                        // `cannotLoad` we sharpen it with a "load se nepovede"
                        // note. Download is still permitted because the user
                        // may free memory before they tap Load — the load
                        // gate itself remains the source of truth.
                        Text(downloadDialogRiskMessage(for: model))
                    } else {
                        let suffix = model.format == .mlx
                            ? " Downloads continue in the background when the screen is off."
                            : ""
                        if model.sizeBytes > 0 {
                            Text("\(model.sizeFormatted) will be downloaded and stored on this device.\(suffix)")
                        } else {
                            Text("The model will be downloaded and stored on this device.\(suffix)")
                        }
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
            // ── Delete failure surface ──────────────────────────────────────
            // Previously a failed delete (FileManager error, permission
            // issue) was only logged — the model disappeared from the
            // catalog while gigabytes of cache lingered on disk with no
            // recovery path from the UI. The service now publishes
            // `lastDeleteError` for exactly these cases.
            .alert(
                "Delete failed",
                isPresented: Binding(
                    get: { downloads.lastDeleteError != nil },
                    set: { if !$0 { downloads.acknowledgeDeleteError() } }
                )
            ) {
                Button("OK", role: .cancel) {
                    downloads.acknowledgeDeleteError()
                }
            } message: {
                Text(downloads.lastDeleteError ?? "")
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
                        // Soft compatibility badge. Replaces the prior
                        // "Vyžaduje iPad" hard block — the model is still
                        // downloadable and visible; the badge just makes
                        // the risk legible at a glance instead of relying
                        // on the long subtitle below.
                        if isRunningOnPhone && isIPadOnly {
                            experimentalBadge
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
                        Text("Doporučeno pro iPad — na tomto zařízení může selhat kvůli paměti.")
                            .font(HHTheme.caption)
                            .foregroundStyle(HHTheme.warning)
                            .lineLimit(2)
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

    /// Orange "Experimentální" pill shown next to the backend badge when
    /// the catalog entry is recommended for iPad-class hardware only and
    /// we're running on iPhone. Compatibility category 2 in the model
    /// policy — the model is downloadable, but the run is not guaranteed.
    private var experimentalBadge: some View {
        Text("Experimentální")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(HHTheme.warning.opacity(0.18), in: Capsule())
            .foregroundStyle(HHTheme.warning)
            .accessibilityLabel("Experimentální na iPhonu, doporučeno pro iPad")
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
                        .disabled(!item.actions.canDownload)
                        .accessibilityIdentifier("mlx_download_button")
                    // Footer text differs for risky models so the user
                    // understands the download is permitted but the run
                    // is not guaranteed on this hardware.
                    Text(isRunningOnPhone && isIPadOnly
                         ? "Stažení možné · běh nejistý · \(model.sizeFormatted)"
                         : "Background transfer · \(model.sizeFormatted) · tap Load after")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary)
                }
            } else {
                HStack(spacing: HHTheme.spaceS) {
                    Button(item.hasResumeData ? "Resume" : "Download", action: onDownload)
                        .buttonStyle(HHSecondaryButtonStyle())
                        .disabled(!item.actions.canDownload)
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
                            .disabled(!item.actions.canLoad)
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
                        .disabled(!item.actions.canUnload)
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
                    // Retry always re-triggers the download for both
                    // formats. The previous wiring routed MLX retry to
                    // onLoad(), which never fires because the row is
                    // still .downloadFailed (not .installed) — the
                    // button was permanently disabled by canLoad=false.
                    Button(item.hasResumeData ? "Resume" : "Retry", action: onDownload)
                        .buttonStyle(HHSecondaryButtonStyle())
                        .disabled(!item.actions.canDownload)
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
                        .disabled(!item.actions.canLoad)
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
