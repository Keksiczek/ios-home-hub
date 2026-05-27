import SwiftUI

struct OnboardingModelPickerView: View {
    @EnvironmentObject private var service: OnboardingService
    @EnvironmentObject private var catalog: ModelCatalogService
    @EnvironmentObject private var downloads: ModelDownloadService
    @ObservedObject var drafts: OnboardingDrafts

    /// Sort order: usable-in-this-build first (MLX-default builds get MLX up
    /// top), then disabled-with-reason at the bottom. Stable: keeps catalog
    /// declaration order within each group.
    @State private var showAllModels = false

    /// Recommended models (MLX and usable)
    private var recommendedModels: [LocalModel] {
        catalog.models.filter { $0.isUsableInThisBuild && $0.backend == .mlx }
    }

    /// Other models (GGUF or non-usable)
    private var otherModels: [LocalModel] {
        catalog.models.filter { !recommendedModels.contains($0) }
    }

    var body: some View {
        HHScreen(
            eyebrow: "Step 1",
            title: "Choose a model.",
            subtitle: "Select a model to get started. HomeHub runs entirely on-device for maximum privacy."
        ) {
            VStack(spacing: HHTheme.spaceM) {
                SectionHeader(title: "Recommended", subtitle: "Optimized for your device")
                
                ForEach(recommendedModels) { model in
                    ModelPickerRow(
                        model: model,
                        isSelected: drafts.selectedModelID == model.id,
                        hasResumeData: downloads.hasResumeData(for: model.id),
                        onSelect: { drafts.selectedModelID = model.id },
                        onDownload: { downloads.start(model) }
                    )
                }

                if !otherModels.isEmpty {
                    if showAllModels {
                        SectionHeader(title: "Other Models", subtitle: "Alternative formats and legacy models")
                            .padding(.top, HHTheme.spaceM)
                        
                        ForEach(otherModels) { model in
                            ModelPickerRow(
                                model: model,
                                isSelected: drafts.selectedModelID == model.id,
                                hasResumeData: downloads.hasResumeData(for: model.id),
                                onSelect: {
                                    guard model.isUsableInThisBuild else { return }
                                    drafts.selectedModelID = model.id
                                },
                                onDownload: { downloads.start(model) }
                            )
                        }
                    } else {
                        Button {
                            withAnimation { showAllModels = true }
                        } label: {
                            Text("Show more formats…")
                                .font(HHTheme.caption)
                                .foregroundStyle(HHTheme.accent)
                                .padding(.vertical, HHTheme.spaceS)
                        }
                    }
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
        case .mlx:                   return HHTheme.accent
        case .llamaCpp:              return HHTheme.textSecondary
        // Core ML SD models are image-generation only (no LLM
        // role) and onboarding does not surface them as a primary
        // pick — but the badge still needs a colour when these
        // models show up in any picker that reuses this row.
        case .coreML:                return HHTheme.textSecondary
        case .appleFoundationModels: return HHTheme.accent
        }
    }

    private var badgeBackground: Color {
        switch model.backend {
        case .mlx:                   return HHTheme.accent.opacity(0.15)
        case .llamaCpp:              return HHTheme.textSecondary.opacity(0.12)
        case .coreML:                return HHTheme.textSecondary.opacity(0.12)
        case .appleFoundationModels: return HHTheme.accent.opacity(0.15)
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
                // MLX models download automatically on first load via the
                // Hugging Face Hub — never via the GGUF URLSession pipeline.
                // Showing a GGUF "Download" button here would call
                // downloads.start() → GGUF magic check failure on every
                // MLX model, leaving them all in the .failed state before
                // the user even leaves onboarding.
                if model.format != .mlx {
                    Button("Download", action: onDownload)
                        .font(HHTheme.subheadline)
                        .tint(HHTheme.accent)
                } else {
                    Text("Downloads on first use")
                        .font(HHTheme.caption)
                        .foregroundStyle(HHTheme.textSecondary.opacity(0.7))
                }
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

private struct SectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(HHTheme.textSecondary)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(HHTheme.caption)
                    .foregroundStyle(HHTheme.textSecondary.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
