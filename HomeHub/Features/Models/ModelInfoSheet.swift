import SwiftUI

/// Detailed info sheet for a single model — shown when the user taps
/// the info button in the model list.
struct ModelInfoSheet: View {
    let model: LocalModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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

                Section("Identity") {
                    row("Family",        model.family)
                    row("Parameters",    model.parameterCount)
                    row("Quantization",  model.quantization)
                }

                Section("Requirements") {
                    row("File size",     model.sizeFormatted)
                    row("RAM estimate",  estimatedRAM)
                    row("Context",       "\(model.contextLength) tokens")
                }

                Section("Source") {
                    row("License",       model.license)
                    row("Host",          downloadHost)
                }

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

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ label: String?, _ value: String) -> some View {
        if let label {
            LabeledContent(label, value: value)
        } else {
            Text(value)
        }
    }

    /// Rough RAM estimate: file size + a fixed 1.5 GB for KV cache and
    /// runtime overhead at default context length. Errs on the high side.
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
