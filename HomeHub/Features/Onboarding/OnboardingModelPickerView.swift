import SwiftUI

struct OnboardingModelPickerView: View {
    @EnvironmentObject private var service: OnboardingService
    @EnvironmentObject private var catalog: ModelCatalogService
    @EnvironmentObject private var downloads: ModelDownloadService
    @ObservedObject var drafts: OnboardingDrafts

    /// Sort order: usable-in-this-build first (MLX-default builds get MLX up
    /// top), then disabled-with-reason at the bottom. Stable: keeps catalog
    /// declaration order within each group.
    private var orderedModels: [LocalModel] {
        let usable = catalog.models.filter { $0.isUsableInThisBuild }
        let disabled = catalog.models.filter { !$0.isUsableInThisBuild }
        return usable + disabled
    }

    var body: some View {
        HHScreen(
            eyebrow: "Step 1",
            title: "Choose a model.",
            subtitle: "Download a model to get started. The app runs entirely on-device — no model, no chat. You can add more or import custom models later from Settings → Models."
        ) {
            VStack(spacing: HHTheme.spaceM) {
                ForEach(orderedModels) { model in
                    ModelPickerRow(
                        model: model,
                        isSelected: drafts.selectedModelID == model.id,
                        // Resume picks up an interrupted download from
                        // its saved bytes; bare retry starts over. Both
                        // funnel through `downloads.start(_:)` which
                        // looks up the resume blob internally.
                        hasResumeData: downloads.hasResumeData(for: model.id),
                        onSelect: {
                            // Refuse to select a model the build can't load.
                            // The row already shows a disabled affordance and
                            // the unavailable reason; this stops the user from
                            // sailing through onboarding into a hard error.
                            guard model.isUsableInThisBuild else { return }
                            drafts.selectedModelID = model.id
                        },
                        onDownload: { downloads.start(model) }
                    )
                }
            }
        } footer: {
            VStack(spacing: HHTheme.spaceS) {
                Button("Continue") {
                    Task { await service.advance(to: .assistantStyle) }
                }
                .buttonStyle(HHPrimaryButtonStyle())
                .disabled(drafts.selectedModelID == nil)
                .opacity(drafts.selectedModelID == nil ? 0.5 : 1.0)

                if drafts.selectedModelID != nil {
                    let selectedState = catalog.model(withID: drafts.selectedModelID ?? "")?.installState
                    if case .notInstalled = selectedState ?? .notInstalled {
                        Text("You can continue and download the model later from Models tab.")
                            .font(HHTheme.caption)
                            .foregroundStyle(HHTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }

                Button("Back") {
                    Task { await service.back(to: .welcome) }
                }
                .buttonStyle(HHQuietButtonStyle())
            }
        }
        .onAppear {
            // recommendedStarter is guaranteed-usable (it filters by backend
            // availability in the catalog service) — safe to set blindly.
            if drafts.selectedModelID == nil {
                drafts.selectedModelID = catalog.recommendedStarter.id
            }
        }
    }
}

private struct ModelPickerRow: View {
    let model: LocalModel
    let isSelected: Bool
    /// True when a previous download for this model failed but resume
    /// data is still around. Toggles the recovery button label between
    /// "Resume" and "Retry" so the user knows whether the second attempt
    /// continues the previous bytes or starts over.
    let hasResumeData: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HHCard {
            VStack(alignment: .leading, spacing: HHTheme.spaceM) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: HHTheme.spaceS) {
                            Text(model.displayName)
                                .font(HHTheme.headline)
                            backendBadge
                        }
                        Text("\(model.parameterCount) · \(model.quantization) · \(model.sizeFormatted)")
                            .font(HHTheme.footnote)
                            .foregroundStyle(HHTheme.textSecondary)
                    }
                    Spacer(minLength: HHTheme.spaceM)
                    selectionIndicator
                }

                if let reason = model.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.warning)
                        .lineLimit(3)
                } else {
                    stateRow
                }
            }
        }
        .contentShape(Rectangle())
        .opacity(model.isUsableInThisBuild ? 1.0 : 0.55)
        .onTapGesture(perform: onSelect)
    }

    /// Compact "MLX" / "GGUF" pill so users see at a glance which runtime a
    /// row is targeting before they pick it. The catalog ships both formats
    /// even on MLX-only builds so users understand what the opt-in flag would
    /// unlock.
    private var backendBadge: some View {
        Text(model.backend.displayName)
            .font(HHTheme.caption.bold())
            .foregroundStyle(badgeForeground)
            .padding(.horizontal, HHTheme.spaceS)
            .padding(.vertical, 2)
            .background(badgeBackground, in: Capsule())
    }

    private var badgeForeground: Color {
        switch model.backend {
        case .mlx:      return HHTheme.accent
        case .llamaCpp: return HHTheme.textSecondary
        }
    }

    private var badgeBackground: Color {
        switch model.backend {
        case .mlx:      return HHTheme.accent.opacity(0.15)
        case .llamaCpp: return HHTheme.textSecondary.opacity(0.12)
        }
    }

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(isSelected ? HHTheme.accent : HHTheme.textSecondary.opacity(0.4))
    }

    @ViewBuilder
    private var stateRow: some View {
        switch model.installState {
        case .notInstalled:
            HStack {
                Text("Not downloaded")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
                Spacer()
                Button("Download", action: onDownload)
                    .font(HHTheme.subheadline)
                    .tint(HHTheme.accent)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .tint(HHTheme.accent)
                Text("Downloading · \(Int(progress * 100))%")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary)
            }
        case .installed:
            Label("Ready", systemImage: "checkmark.seal.fill")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.success)
        case .loaded:
            Label("Loaded", systemImage: "bolt.fill")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.accent)
        case .failed(let reason):
            // Failed downloads must surface a recovery affordance —
            // without one, the only path forward is "Reset all models"
            // in dev diagnostics, which is brutal during onboarding.
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.warning)
                    .lineLimit(3)
                Button(hasResumeData ? "Resume" : "Try again", action: onDownload)
                    .font(HHTheme.subheadline)
                    .tint(HHTheme.accent)
            }
        }
    }
}
