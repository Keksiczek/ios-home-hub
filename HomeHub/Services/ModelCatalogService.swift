import Foundation
import SwiftUI

/// The list of models the user can pick from. In v1 the catalog is
/// hard-coded and vetted for iPhone 16 Pro / M-series iPad. Future:
/// fetch a signed JSON manifest from a pinned endpoint.
@MainActor
final class ModelCatalogService: ObservableObject {
    @Published private(set) var models: [LocalModel]

    init(models: [LocalModel] = ModelCatalog.curated) {
        self.models = models
    }

    func model(withID id: String) -> LocalModel? {
        models.first { $0.id == id }
    }

    func update(_ model: LocalModel) {
        if let idx = models.firstIndex(where: { $0.id == model.id }) {
            models[idx] = model
        } else {
            models.append(model)
        }
    }

    func setInstallState(_ state: ModelInstallState, for modelID: String) {
        guard let idx = models.firstIndex(where: { $0.id == modelID }) else { return }
        models[idx].installState = state
    }

    var recommendedStarter: LocalModel {
        // Llama 3.2 3B is the safe default — fits on iPhone, fast, warm.
        models.first(where: { $0.id == "llama-3.2-3b-instruct-q4_k_m" }) ?? models[0]
    }
}

// MARK: - Curated model catalog

enum ModelCatalog {
    /// Curated list of models tested on iPhone 16 Pro and M-series iPad.
    ///
    /// Download URLs point to HuggingFace GGUF repositories. When
    /// `HOMEHUB_REAL_RUNTIME` is set, `ModelDownloadService` fetches
    /// these URLs with progress tracking and optional SHA-256
    /// verification. In development builds, downloads are simulated.
    ///
    /// SHA-256 hashes are left nil because the upstream files may be
    /// re-quantised. Set them after verifying a known-good download
    /// to enable integrity checks.
    static let curated: [LocalModel] = [
        LocalModel(
            id: "llama-3.2-3b-instruct-q4_k_m",
            displayName: "Llama 3.2 3B Instruct",
            family: "Llama",
            parameterCount: "3B",
            quantization: "Q4_K_M",
            sizeBytes: 2_100_000_000,
            contextLength: 8192,
            downloadURL: URL(string:
                "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
            )!,
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Llama 3.2 Community License"
        ),
        LocalModel(
            id: "phi-3.5-mini-instruct-q4_k_m",
            displayName: "Phi 3.5 Mini Instruct",
            family: "Phi",
            parameterCount: "3.8B",
            quantization: "Q4_K_M",
            sizeBytes: 2_400_000_000,
            contextLength: 4096,
            downloadURL: URL(string:
                "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf"
            )!,
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "MIT"
        ),
        LocalModel(
            id: "qwen-2.5-3b-instruct-q5_k_m",
            displayName: "Qwen 2.5 3B Instruct",
            family: "Qwen",
            parameterCount: "3B",
            quantization: "Q5_K_M",
            sizeBytes: 2_500_000_000,
            contextLength: 8192,
            downloadURL: URL(string:
                "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q5_k_m.gguf"
            )!,
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Apache 2.0"
        ),
        LocalModel(
            id: "llama-3.1-8b-instruct-q4_k_m",
            displayName: "Llama 3.1 8B Instruct",
            family: "Llama",
            parameterCount: "8B",
            quantization: "Q4_K_M",
            sizeBytes: 4_800_000_000,
            contextLength: 8192,
            downloadURL: URL(string:
                "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
            )!,
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],
            license: "Llama 3.1 Community License"
        )
    ]
}
