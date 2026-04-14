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
    /// True for models added via "Add from URL" — persisted in user-models.json,
    /// not part of the curated catalog.
    var isUserAdded: Bool

    var sizeFormatted: String {
        guard sizeBytes > 0 else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    // MARK: - Codable (migration-safe)

    private enum CodingKeys: String, CodingKey {
        case id, displayName, family, parameterCount, quantization
        case sizeBytes, contextLength, downloadURL, sha256
        case installState, recommendedFor, license, isUserAdded
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
        isUserAdded   = try c.decodeIfPresent(Bool.self, forKey: .isUserAdded) ?? false
    }
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
