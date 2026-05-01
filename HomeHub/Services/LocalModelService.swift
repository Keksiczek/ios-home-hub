import Foundation
import OSLog

/// Tri-state representation of an externally-managed MLX model cache.
enum MLXCacheState {
    /// Directory or essential metadata is missing.
    case missing
    /// Metadata exists, but weights are missing or suspiciously small.
    case partial
    /// Strong evidence the cache is fully usable.
    case ready
}

/// Owns the on-disk model directory. Nobody else touches model
/// files directly — everyone asks this actor for paths and sizes.
actor LocalModelService {
    private let fileManager = FileManager.default
    private let modelsDirectory: URL
    private let baseDocumentsDirectory: URL
    private let log = Logger(subsystem: "com.keksiczek.HomeHub", category: "LocalModelService")

    init(baseDocumentsDirectory: URL = .documentsDirectory) {
        self.baseDocumentsDirectory = baseDocumentsDirectory
        
        // Non-failable iOS 16+ accessor.
        let support = URL.applicationSupportDirectory
        self.modelsDirectory = support.appendingPathComponent("Models", isDirectory: true)
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    func localURL(for modelID: String) -> URL {
        modelsDirectory.appendingPathComponent("\(modelID).gguf")
    }

    // MARK: - MLX Cache Support
    
    /// Resolves the default MLXLMCommon / swift-transformers cache directory for a given repo.
    /// Format: `<baseDocumentsDirectory>/huggingface/models/<repoId>`
    private func mlxCacheURL(for repoId: String) -> URL {
        return baseDocumentsDirectory.appendingPathComponent("huggingface/models/\(repoId)")
    }
    
    /// Conservatively evaluates the readiness of an MLX model cache.
    /// - Returns: `MLXCacheState` (missing, partial, or ready).
    private func mlxCacheState(for repoId: String) -> MLXCacheState {
        let cacheDir = mlxCacheURL(for: repoId)
        
        // 1. Directory must exist
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: cacheDir.path, isDirectory: &isDir), isDir.boolValue else {
            return .missing
        }
        
        // 2. config.json must exist
        let configPath = cacheDir.appendingPathComponent("config.json").path
        guard fileManager.fileExists(atPath: configPath) else {
            return .missing
        }
        
        // 3. Evaluate weights (.safetensors)
        guard let contents = try? fileManager.contentsOfDirectory(atPath: cacheDir.path) else {
            return .missing
        }
        
        let safetensorsFiles = contents.filter { $0.hasSuffix(".safetensors") }
        if safetensorsFiles.isEmpty {
            log.debug("MLX Cache [\(repoId)]: Metadata found, but no weights (.safetensors) exist. State: partial")
            return .partial
        }
        
        // 4. Sanity check: Ensure weights are not trivially small (e.g. < 1MB)
        // This helps detect interrupted downloads where a file was touched but not filled.
        var totalWeightsSize: Int64 = 0
        for file in safetensorsFiles {
            let path = cacheDir.appendingPathComponent(file).path
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64 {
                totalWeightsSize += size
            }
        }
        
        if totalWeightsSize < 1_000_000 {
            log.debug("MLX Cache [\(repoId)]: Weights are trivially small (\(totalWeightsSize) bytes). State: partial")
            return .partial
        }
        
        log.info("MLX Cache [\(repoId)]: Strong evidence of usability found. State: ready")
        return .ready
    }
    
    /// Returns a mapping of Model IDs to their current MLX cache state.
    func mlxCacheStates(catalogModels: [LocalModel]) -> [String: MLXCacheState] {
        let mlxModels = catalogModels.filter { $0.format == .mlx }
        var states = [String: MLXCacheState]()
        
        for model in mlxModels {
            guard let repoId = model.repoId else { continue }
            states[model.id] = mlxCacheState(for: repoId)
        }
        
        return states
    }
    
    /// Public helper to get the resolved local URL for an installed MLX model
    func resolvedMLXCacheURL(for repoId: String) -> URL {
        mlxCacheURL(for: repoId)
    }

    // MARK: - GGUF Support
    func isInstalled(_ modelID: String) -> Bool {
        fileManager.fileExists(atPath: localURL(for: modelID).path)
    }

    func remove(_ modelID: String) throws {
        let url = localURL(for: modelID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Returns `true` when the model file exists but is not a valid GGUF.
    ///
    /// Two checks mirror the validation in `LlamaCppRuntime.validateGGUFFile`:
    /// 1. **Size < 1 MB** — dev-mode stub files (`"STUB_MODEL"` = 10 bytes).
    /// 2. **GGUF magic** — first 4 bytes must be `0x47 0x47 0x55 0x46`.
    ///
    /// Returns `false` when the file doesn't exist (not installed at all).
    func isStubOrInvalidGGUF(_ modelID: String) -> Bool {
        let url = localURL(for: modelID)
        guard fileManager.fileExists(atPath: url.path) else { return false }

        // Size check: real quantised models are hundreds of MB.
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64,
           size < 1_000_000 {
            return true
        }

        // GGUF magic-bytes check (G G U F = 0x47 0x47 0x55 0x46).
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        return magic != Data([0x47, 0x47, 0x55, 0x46])
    }

    /// Returns file size in bytes for a model file, or nil if file doesn't exist.
    func fileSizeBytes(for modelID: String) -> Int64? {
        let url = localURL(for: modelID)
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    /// Returns the set of model IDs (filename stem) for which a valid GGUF
    /// file exists on disk. Used by bootstrap to reconcile catalog states.
    func installedModelIDs() -> Set<String> {
        let contents = (try? fileManager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        return Set(
            contents
                .filter { $0.pathExtension == "gguf" }
                .compactMap { url -> String? in
                    let modelID = url.deletingPathExtension().lastPathComponent
                    return isStubOrInvalidGGUF(modelID) ? nil : modelID
                }
        )
    }

    /// Returns every .gguf file URL in the models directory, whether or not
    /// it corresponds to a catalog model. Used to surface orphaned files.
    func allGGUFFiles() -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        )) ?? []
        return contents.filter { $0.pathExtension == "gguf" }
    }

    /// Removes all `.gguf` files from the models directory.
    /// Call via `ModelDownloadService.resetAllModels()` which also
    /// cancels downloads and resets catalog state.
    func removeAll() throws {
        let contents = (try? fileManager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for url in contents where url.pathExtension == "gguf" {
            try fileManager.removeItem(at: url)
        }
    }

    func totalStorageBytes() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
