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
