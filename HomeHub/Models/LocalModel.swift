import Foundation

/// Metadata + install state for a local on-device model.
///
/// `installState` is the single source of truth for UI status badges
/// in `ModelsView` and the model picker inside onboarding. The
/// runtime layer is responsible for transitioning state to `.loaded`
/// only after a successful `RuntimeManager.load(...)`.
struct LocalModel: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var displayName: String
    var family: String
    var parameterCount: String
    var quantization: String
    var sizeBytes: Int64
    var contextLength: Int
    var downloadURL: URL
    var sha256: String?
    var installState: ModelInstallState
    var recommendedFor: [DeviceClass]
    var license: String
    /// The runtime engine required to run this model.
    var backend: ModelBackend
    /// The underlying file format (e.g. GGUF for llama.cpp, MLX for Apple MLX).
    var format: ModelFormat
    /// True for models added via "Add from URL" — persisted in user-models.json,
    /// not part of the curated catalog.
    var isUserAdded: Bool

    var sizeFormatted: String {
        guard sizeBytes > 0 else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// Safely extracts the Hugging Face repository ID (e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit")
    /// from the model's `downloadURL`. Returns nil if the URL is not a standard HF repo format.
    var repoId: String? {
        guard format == .mlx, let host = downloadURL.host, host.contains("huggingface.co") else {
            return nil
        }
        let pathComponents = downloadURL.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else { return nil }
        return "\(pathComponents[0])/\(pathComponents[1])"
    }

    // MARK: - Codable (migration-safe)

    private enum CodingKeys: String, CodingKey {
        case id, displayName, family, parameterCount, quantization
        case sizeBytes, contextLength, downloadURL, sha256
        case installState, recommendedFor, license, isUserAdded
        case backend, format
    }

    init(
        id: String,
        displayName: String,
        family: String,
        parameterCount: String,
        quantization: String,
        sizeBytes: Int64,
        contextLength: Int,
        downloadURL: URL,
        sha256: String? = nil,
        installState: ModelInstallState,
        recommendedFor: [DeviceClass],
        license: String,
        backend: ModelBackend = .llamaCpp,
        format: ModelFormat = .gguf,
        isUserAdded: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.sizeBytes = sizeBytes
        self.contextLength = contextLength
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.installState = installState
        self.recommendedFor = recommendedFor
        self.license = license
        self.backend = backend
        self.format = format
        self.isUserAdded = isUserAdded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(String.self, forKey: .id)
        displayName   = try c.decode(String.self, forKey: .displayName)
        family        = try c.decode(String.self, forKey: .family)
        parameterCount = try c.decode(String.self, forKey: .parameterCount)
        quantization  = try c.decode(String.self, forKey: .quantization)
        sizeBytes     = try c.decode(Int64.self,  forKey: .sizeBytes)
        contextLength = try c.decode(Int.self,    forKey: .contextLength)
        downloadURL   = try c.decode(URL.self,    forKey: .downloadURL)
        sha256        = try c.decodeIfPresent(String.self, forKey: .sha256)
        installState  = try c.decodeIfPresent(ModelInstallState.self, forKey: .installState) ?? .notInstalled
        recommendedFor = try c.decodeIfPresent([DeviceClass].self, forKey: .recommendedFor) ?? [.iPhone, .iPadMSeries]
        license       = try c.decodeIfPresent(String.self, forKey: .license) ?? "Unknown"
        backend       = try c.decodeIfPresent(ModelBackend.self, forKey: .backend) ?? .llamaCpp
        format        = try c.decodeIfPresent(ModelFormat.self, forKey: .format) ?? .gguf
        isUserAdded   = try c.decodeIfPresent(Bool.self, forKey: .isUserAdded) ?? false
    }
}

// MARK: - Metadata Types

enum ModelBackend: String, Codable, Sendable {
    case llamaCpp = "llama.cpp"
    case mlx = "mlx"
}

enum ModelFormat: String, Codable, Sendable {
    case gguf = "GGUF"
    case mlx = "MLX"
}

enum ModelInstallState: Codable, Equatable, Hashable {
    case notInstalled
    case downloading(progress: Double)
    case installed(localURL: URL)
    case loaded(localURL: URL)
    case failed(reason: String)

    var isReady: Bool {
        switch self {
        case .installed, .loaded: return true
        default: return false
        }
    }

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

enum DeviceClass: String, Codable, Hashable {
    case iPhone
    case iPadMSeries
}

extension LocalModel {
    static let mockMLX = LocalModel(
        id: "mock-mlx-llama",
        displayName: "Llama 3 (Fake MLX)",
        family: "Llama",
        parameterCount: "8B",
        quantization: "4-bit",
        sizeBytes: 4_000_000_000,
        contextLength: 8192,
        downloadURL: URL(string: "https://huggingface.co/mlx-community/mock-model")!,
        installState: .notInstalled,
        recommendedFor: [.iPhone, .iPadMSeries],
        license: "Llama 3",
        backend: .mlx,
        format: .mlx,
        isUserAdded: false
    )
}
