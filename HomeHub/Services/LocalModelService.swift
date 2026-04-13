import Foundation

/// Owns the on-disk model directory. Nobody else touches model
/// files directly — everyone asks this actor for paths and sizes.
actor LocalModelService {
    private let fileManager = FileManager.default
    private let modelsDirectory: URL

    init() {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.modelsDirectory = support.appendingPathComponent("Models", isDirectory: true)
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    func localURL(for modelID: String) -> URL {
        modelsDirectory.appendingPathComponent("\(modelID).gguf")
    }

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
