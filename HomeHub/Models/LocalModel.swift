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

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
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
