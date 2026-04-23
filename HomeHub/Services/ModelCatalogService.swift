import Foundation
import SwiftUI

/// The list of models the user can pick from. In v1 the curated catalog is
/// hard-coded and vetted for iPhone 16 Pro / M-series iPad. User-added models
/// (via "Add from URL") are persisted in `user-models.json` alongside the
/// catalog and merged at launch.
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
        // Gemma 3 4B is the recommended default — strong reasoning, fits on iPhone.
        models.first(where: { $0.id == "gemma-3-4b-it-q4_k_m" }) ?? models[0]
    }

    /// Smallest iPhone-safe model for smoke-testing a real-runtime device build.
    var iPhoneSmokeTestModel: LocalModel {
        models.first(where: { $0.id == "gemma-2-2b-it-q4_k_m" }) ?? models[0]
    }

    /// Returns `true` when `model` is recommended for iPad M-series only
    /// and is therefore likely to OOM or be very slow on an iPhone.
    func isIPadOnly(_ model: LocalModel) -> Bool {
        !model.recommendedFor.contains(.iPhone)
    }

    // MARK: - User-added model management

    /// Adds a user-defined model to the catalog and saves to disk.
    func addUserModel(_ model: LocalModel) {
        guard !models.contains(where: { $0.id == model.id }) else { return }
        models.append(model)
        saveUserModels()
    }

    /// Removes a user-added model from the catalog and saves to disk.
    func removeUserModel(id: String) {
        models.removeAll { $0.id == id && $0.isUserAdded }
        saveUserModels()
    }

    // MARK: - Disk reconciliation

    /// Reconciles every catalog model's `installState` against actual files on
    /// disk. Must be called at app launch (in `AppContainer.bootstrap()`) before
    /// `autoLoadSelectedModel()` so the UI and runtime never see stale state.
    ///
    /// Rules:
    /// - File exists + valid GGUF → `.installed(localURL:)`
    /// - File absent or stub/invalid → `.notInstalled`
    /// - In-flight `.downloading` states are left untouched (coordinator owns those).
    func reconcileInstallStates(localModels: LocalModelService) async {
        let installed = await localModels.installedModelIDs()
        for idx in models.indices {
            let model = models[idx]
            // Don't disturb an actively-tracked download.
            if case .downloading = model.installState { continue }
            let localURL = await localModels.localURL(for: model.id)
            if installed.contains(model.id) {
                models[idx].installState = .installed(localURL: localURL)
            } else {
                // File gone or invalid — ensure state is consistent.
                if model.installState != .notInstalled {
                    models[idx].installState = .notInstalled
                }
            }
        }
    }

    // MARK: - User model persistence

    func loadUserModels() {
        guard let url = userModelsFileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LocalModel].self, from: data)
        else { return }

        for var model in decoded {
            guard !models.contains(where: { $0.id == model.id }) else { continue }
            // Always load with .notInstalled; reconcileInstallStates() will fix it up.
            model.installState = .notInstalled
            models.append(model)
        }
    }

    private func saveUserModels() {
        guard let url = userModelsFileURL else { return }
        let userModels = models
            .filter { $0.isUserAdded }
            .map { model -> LocalModel in
                var m = model
                m.installState = .notInstalled   // strip runtime state before persisting
                return m
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(userModels) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private var userModelsFileURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support.appendingPathComponent("user-models.json")
    }
}

// MARK: - Curated model catalog

enum ModelCatalog {
    /// Curated list of models tested on iPhone 16 Pro and M-series iPad.
    ///
    /// Download URLs point to HuggingFace GGUF repositories (bartowski builds).
    /// SHA-256 hashes are left nil because upstream files may be re-quantised;
    /// populate them after verifying a known-good download to enable integrity
    /// checks.
    static let curated: [LocalModel] = [

        // MARK: Gemma 3

        LocalModel(
            id: "gemma-3-4b-it-q4_k_m",
            displayName: "Gemma 3 4B Instruct",
            family: "Gemma3",
            parameterCount: "4B",
            quantization: "Q4_K_M",
            sizeBytes: 2_600_000_000,
            contextLength: 8192,
            downloadURL: URL(string:
                "https://huggingface.co/bartowski/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf"
            )!,
            sha256: nil, // TODO: verify hash
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Gemma Terms of Use"
        ),

        LocalModel(
            id: "gemma-3-12b-it-q4_k_m",
            displayName: "Gemma 3 12B Instruct",
            family: "Gemma3",
            parameterCount: "12B",
            quantization: "Q4_K_M",
            sizeBytes: 7_300_000_000,
            contextLength: 8192,
            downloadURL: URL(string:
                "https://huggingface.co/bartowski/gemma-3-12b-it-GGUF/resolve/main/gemma-3-12b-it-Q4_K_M.gguf"
            )!,
            sha256: nil, // TODO: verify hash
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],
            license: "Gemma Terms of Use"
        ),

        // MARK: Gemma 2

        LocalModel(
            id: "gemma-2-2b-it-q4_k_m",
            displayName: "Gemma 2 2B Instruct",
            family: "Gemma2",
            parameterCount: "2B",
            quantization: "Q4_K_M",
            sizeBytes: 1_600_000_000,
            contextLength: 8192,
            downloadURL: URL(string:
                "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf"
            )!,
            sha256: nil, // TODO: verify hash
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Gemma Terms of Use"
        ),

        LocalModel(
            id: "gemma-2-9b-it-q4_k_m",
            displayName: "Gemma 2 9B Instruct",
            family: "Gemma2",
            parameterCount: "9B",
            quantization: "Q4_K_M",
            sizeBytes: 5_400_000_000,
            contextLength: 8192,
            downloadURL: URL(string:
                "https://huggingface.co/bartowski/gemma-2-9b-it-GGUF/resolve/main/gemma-2-9b-it-Q4_K_M.gguf"
            )!,
            sha256: nil, // TODO: verify hash
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],
            license: "Gemma Terms of Use"
        ),

        // MARK: Llama 3.x

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
            sha256: nil, // TODO: verify hash
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Llama 3.2 Community License"
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
            sha256: nil, // TODO: verify hash
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],
            license: "Llama 3.1 Community License"
        ),

        // MARK: Phi / Qwen

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
            sha256: nil, // TODO: verify hash
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
            sha256: nil, // TODO: verify hash
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Apache 2.0"
        ),
    ]
}
