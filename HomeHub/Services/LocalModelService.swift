import Foundation
import OSLog

/// Tri-state representation of an externally-managed MLX model cache.
enum MLXCacheState: Equatable, Sendable {
    /// Directory or essential metadata is missing.
    case missing
    /// Metadata exists, but weights are missing or suspiciously small.
    case partial
    /// Strong evidence the cache is fully usable.
    case ready
}

/// Detailed snapshot of an MLX cache directory — used by the download
/// finalizer and the runtime pre-flight to give actionable error
/// messages instead of "Failed to load MLX model".
struct MLXCacheInspection: Sendable, Equatable {
    var state: MLXCacheState
    /// True if the cache directory itself exists on disk.
    var directoryExists: Bool
    /// True if `config.json` is present.
    var hasConfig: Bool
    /// True if `config.json` is parseable as JSON AND contains the minimal
    /// fields swift-transformers' `LanguageModelConfigurationFromHub.loadConfig`
    /// inspects. False here turns into a hard `.partial` even if the file
    /// exists, because handing corrupted JSON to `HubApi.configuration(fileURL:)`
    /// previously SIGABRT'd inside `NSJSONReader.parseData` (FACT_FROM_LOG).
    var configJSONIsValid: Bool
    /// True if at least one `*.safetensors` weight shard is present.
    var hasWeights: Bool
    /// True if a tokenizer artefact is present (`tokenizer.json`,
    /// `tokenizer.model`, `vocab.json` + `merges.txt`, …). Conservative —
    /// missing tokenizer is a hard failure on every MLX loader path.
    var hasTokenizer: Bool
    /// Sum of weight-shard sizes; useful for telemetry / "weights are
    /// suspiciously small" sanity checks.
    var totalWeightsBytes: Int64
    /// Human-readable list of what's missing. Empty when `state == .ready`.
    var missingItems: [String]
    /// Detected model family from `config.json` (`"Llama"`, `"Gemma3"`,
    /// `"Qwen"`, …). `nil` if `config.json` is missing or unparsable.
    /// Used by `ModelCatalogService.upgradeCustomFamilyIfDetected` to
    /// promote user-added MLX models out of the generic "Custom"
    /// family so `ChatTemplate` picks the right render path in the
    /// tokenizer-bridge fallback.
    var detectedFamily: String?

    /// One-line, user-facing reason suitable for `.failed(reason:)`.
    /// Returns `nil` when the cache is ready.
    var failureReason: String? {
        switch state {
        case .ready:
            return nil
        case .missing where !directoryExists:
            return "Model directory is missing on disk."
        case .missing, .partial:
            if hasConfig && !configJSONIsValid {
                return "Model config.json is corrupted — re-download the model."
            }
            if missingItems.isEmpty {
                return "Model directory is incomplete."
            }
            return "Model directory is incomplete — missing: \(missingItems.joined(separator: ", "))."
        }
    }
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
        inspectMLXCache(for: repoId).state
    }

    /// Detailed inspection of an MLX cache. Used both by post-download
    /// finalization (where we need an actionable failure reason if the
    /// cache is partial) and by the runtime pre-flight before invoking
    /// the MLX loader (so we fail fast with a clear message instead of
    /// throwing the loader's internal error string at the user).
    func inspectMLXCache(for repoId: String) -> MLXCacheInspection {
        Self.inspectMLXCache(
            at: mlxCacheURL(for: repoId)
        )
    }

    /// Off-actor variant used by the runtime pre-flight path. Computes
    /// the cache URL the same way the actor would, then delegates to the
    /// directory-based inspector. `baseDocuments` defaults to
    /// `URL.documentsDirectory` — the same value the production
    /// `LocalModelService` is constructed with.
    nonisolated static func inspectMLXCache(
        repoId: String,
        baseDocuments: URL = URL.documentsDirectory
    ) -> MLXCacheInspection {
        let cacheDir = baseDocuments.appendingPathComponent("huggingface/models/\(repoId)")
        return inspectMLXCache(at: cacheDir)
    }

    /// Directory-based inspector. Pure file-system read — safe off any
    /// actor. Returns the same structured snapshot as the actor-isolated
    /// method so the two call sites can share `.failureReason` logic.
    nonisolated static func inspectMLXCache(at cacheDir: URL) -> MLXCacheInspection {
        let fileManager = FileManager.default
        let staticLog = Logger(subsystem: "com.keksiczek.HomeHub", category: "LocalModelService")

        var isDir: ObjCBool = false
        let dirExists = fileManager.fileExists(atPath: cacheDir.path, isDirectory: &isDir) && isDir.boolValue
        guard dirExists else {
            staticLog.debug("MLX Cache: directory missing at \(cacheDir.path, privacy: .public)")
            return MLXCacheInspection(
                state: .missing,
                directoryExists: false,
                hasConfig: false,
                configJSONIsValid: false,
                hasWeights: false,
                hasTokenizer: false,
                totalWeightsBytes: 0,
                missingItems: ["model directory"],
                detectedFamily: nil
            )
        }

        let contents = (try? fileManager.contentsOfDirectory(atPath: cacheDir.path)) ?? []

        let hasConfig = contents.contains("config.json")
        // Pre-validate config.json BEFORE the loader hands it to
        // `HubApi.configuration(fileURL:)`. swift-transformers calls
        // `NSJSONReader.parseData(...)` directly on the file bytes —
        // when the file is truncated or contains invalid UTF-8 the
        // parser data-aborts (SIGSEGV-style) inside
        // `CFStringCreateImmutableFunnel3` before any Swift `catch`
        // can fire. Validating here turns a process crash into a
        // recoverable `.partial` state with a user-actionable reason.
        let configJSONIsValid: Bool = {
            guard hasConfig else { return false }
            let url = cacheDir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            // Empty / single-byte files crash NSJSONReader on some iOS revs.
            guard data.count >= 2 else { return false }
            // Strict UTF-8 round-trip: rejects truncated multibyte sequences
            // that survived the file read but blow up CFString.
            guard String(data: data, encoding: .utf8) != nil else { return false }
            do {
                let raw = try JSONSerialization.jsonObject(with: data, options: [])
                // swift-transformers expects a top-level dict. Top-level
                // arrays / scalars are valid JSON but make `loadConfig`
                // crash when it asks for keys.
                return raw is [String: Any]
            } catch {
                staticLog.error("MLX Cache: config.json at \(cacheDir.lastPathComponent, privacy: .public) failed JSON validation: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }()
        let safetensorsFiles = contents.filter { $0.hasSuffix(".safetensors") }
        let hasWeights = !safetensorsFiles.isEmpty
        // Conservative tokenizer detection: any of the well-known artefacts
        // satisfies the check. Mirrors what swift-transformers /
        // AutoTokenizer can actually consume.
        let tokenizerCandidates: Set<String> = [
            "tokenizer.json", "tokenizer.model",
            "spiece.model", "sentencepiece.model",
            "vocab.json", "tokenizer_config.json"
        ]
        let hasTokenizer = contents.contains { tokenizerCandidates.contains($0) }
            || contents.contains { $0.hasSuffix(".model") && ($0.contains("tokenizer") || $0.contains("spiece")) }

        var totalWeightsSize: Int64 = 0
        for file in safetensorsFiles {
            let path = cacheDir.appendingPathComponent(file).path
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                totalWeightsSize += size
            }
        }

        var missing: [String] = []
        if !hasConfig    { missing.append("config.json") }
        if hasConfig && !configJSONIsValid { missing.append("valid config.json (file is corrupted)") }
        if !hasTokenizer { missing.append("tokenizer files") }
        if !hasWeights   { missing.append(".safetensors weights") }

        let state: MLXCacheState
        if missing.isEmpty && totalWeightsSize >= 1_000_000 {
            state = .ready
            staticLog.info("MLX Cache: ready at \(cacheDir.lastPathComponent, privacy: .public) (weights=\(totalWeightsSize) B)")
        } else if !missing.isEmpty {
            state = !hasConfig || !hasTokenizer ? .missing : .partial
            staticLog.debug("MLX Cache: incomplete at \(cacheDir.lastPathComponent, privacy: .public) — missing \(missing.joined(separator: ", "), privacy: .public)")
        } else {
            // weights present but suspiciously small (< 1 MB total)
            state = .partial
            staticLog.debug("MLX Cache: weights trivially small at \(cacheDir.lastPathComponent, privacy: .public) (\(totalWeightsSize) B)")
        }

        // Best-effort family detection from config.json. Failures are
        // silent — the value is only used as a UI / template hint.
        // Skip when JSON is invalid so we don't redo the validation read.
        let detectedFamily: String? = (hasConfig && configJSONIsValid)
            ? detectMLXFamily(configURL: cacheDir.appendingPathComponent("config.json"))
            : nil

        return MLXCacheInspection(
            state: state,
            directoryExists: true,
            hasConfig: hasConfig,
            configJSONIsValid: configJSONIsValid,
            hasWeights: hasWeights,
            hasTokenizer: hasTokenizer,
            totalWeightsBytes: totalWeightsSize,
            missingItems: missing,
            detectedFamily: detectedFamily
        )
    }

    /// Reads `config.json` and maps the model architecture / model_type
    /// to one of the `ChatTemplate.render` family strings. Returns
    /// `nil` if the file is missing, unparsable, or doesn't carry a
    /// recognised architecture. Mirrors the catalog's family strings so
    /// a promoted user-added entry behaves like a curated one.
    nonisolated static func detectMLXFamily(configURL: URL) -> String? {
        guard let data = try? Data(contentsOf: configURL, options: .mappedIfSafe),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let archCandidate: String?
        if let arr = raw["architectures"] as? [String], let first = arr.first {
            archCandidate = first
        } else if let mt = raw["model_type"] as? String {
            archCandidate = mt
        } else {
            archCandidate = nil
        }
        guard let arch = archCandidate?.lowercased() else { return nil }

        if arch.contains("llama")                              { return "Llama" }
        if arch.contains("gemma3n")                            { return "Gemma3n" }
        if arch.contains("gemma3")                             { return "Gemma3" }
        if arch.contains("gemma2")                             { return "Gemma2" }
        if arch.contains("gemma")                              { return "Gemma3" }
        if arch.contains("qwen")                               { return "Qwen" }
        if arch.contains("phi")                                { return "Phi" }
        if arch.contains("mistral")                            { return "Mistral" }
        if arch.contains("smollm")                             { return "SmolLM2" }
        return nil
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

    /// Removes the MLX cache directory for a given repository.
    func removeMLXCache(for repoId: String) throws {
        let cacheDir = mlxCacheURL(for: repoId)
        if fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.removeItem(at: cacheDir)
            log.info("Deleted MLX cache directory for '\(repoId, privacy: .public)'")
        }
    }

    /// Enumerates every on-disk MLX cache `org/repo` pair under the
    /// `huggingface/models/` root. Used by the catalog reconcile step
    /// to identify orphaned caches (directory exists but no catalog
    /// entry references it) so they can be removed before reclaiming
    /// disk space at user request.
    func enumerateMLXCacheRepos() -> [String] {
        let root = baseDocumentsDirectory.appendingPathComponent("huggingface/models")
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let orgs = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var result: [String] = []
        for org in orgs {
            let orgDir = root.appendingPathComponent(org)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: orgDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let repos = (try? fileManager.contentsOfDirectory(atPath: orgDir.path)) ?? []
            for repo in repos {
                let repoDir = orgDir.appendingPathComponent(repo)
                var isRepoDir: ObjCBool = false
                if fileManager.fileExists(atPath: repoDir.path, isDirectory: &isRepoDir), isRepoDir.boolValue {
                    result.append("\(org)/\(repo)")
                }
            }
        }
        return result
    }

    /// Returns the on-disk size (in bytes) of an MLX cache, or 0 if
    /// the directory is missing or unreadable. Used by orphan cleanup
    /// telemetry so the user sees how much was reclaimed.
    func mlxCacheSizeBytes(for repoId: String) -> Int64 {
        let cacheDir = mlxCacheURL(for: repoId)
        guard let enumerator = fileManager.enumerator(
            at: cacheDir,
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
