import SwiftUI

struct OnboardingModelPickerView: View {
    @EnvironmentObject private var service: OnboardingService
    @EnvironmentObject private var catalog: ModelCatalogService
    @EnvironmentObject private var downloads: ModelDownloadService
    @ObservedObject var drafts: OnboardingDrafts

    var body: some View {
        HHScreen(
            eyebrow: "Step 1",
            title: "Choose a model.",
            subtitle: "Download a model to get started. The app runs entirely on-device — no model, no chat. You can add more or import custom models later from Settings → Models."
        ) {
            VStack(spacing: HHTheme.spaceM) {
                ForEach(catalog.models) { model in
                    ModelPickerRow(
                        model: model,
                        isSelected: drafts.selectedModelID == model.id,
                        onSelect: { drafts.selectedModelID = model.id },
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
            if drafts.selectedModelID == nil {
                drafts.selectedModelID = catalog.recommendedStarter.id
            }
        }
    }
}

private struct ModelPickerRow: View {
    let model: LocalModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HHCard {
            VStack(alignment: .leading, spacing: HHTheme.spaceM) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.displayName)
                            .font(HHTheme.headline)
                        Text("\(model.parameterCount) · \(model.quantization) · \(model.sizeFormatted)")
                            .font(HHTheme.footnote)
                            .foregroundStyle(HHTheme.textSecondary)
                    }
                    Spacer(minLength: HHTheme.spaceM)
                    selectionIndicator
                }

                stateRow
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
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
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(HHTheme.caption)
                .foregroundStyle(HHTheme.warning)
                .lineLimit(2)
        }
    }
}
