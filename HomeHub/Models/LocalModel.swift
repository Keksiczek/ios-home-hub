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
    /// Upstream commit SHA of the MLX repo at the moment of the most
    /// recent successful install. `nil` for GGUF models (the catalog
    /// entry's static `sha256` already pins a specific file) and for
    /// MLX models installed before this field existed. When set, the
    /// catalog can compare this against `HFModelManifest.sha` on a
    /// later manifest fetch to detect that upstream has moved — i.e.
    /// surface an "Updates available" affordance without breaking the
    /// currently installed copy.
    var installedRepoSHA: String?
    /// `true` for models whose Hugging Face repository requires user
    /// authentication (Google Gemma, Llama 3 8B+, anything behind a
    /// licence-accept gate). Set in the curated catalog; user-added
    /// MLX models default to `false` and get re-tagged at install time
    /// if the manifest fetch returns 401/403.
    ///
    /// Surfaced by the catalog UI as a "Vyžaduje přihlášení" badge and
    /// used by `ModelDownloadService` to short-circuit the manifest
    /// fetch when no HF token is configured (showing a clearer error
    /// than `401 Unauthorized`).
    var requiresAuth: Bool
    /// `true` for models whose weights ship as a single safetensors
    /// shard larger than the ~2 GB iOS sandbox contiguous-mmap ceiling.
    /// Without the `com.apple.developer.kernel.extended-virtual-addressing`
    /// entitlement (paid Apple Developer Program + provisioning profile,
    /// or TrollStore on iOS ≤ 17.0) the load will fail inside MLX's
    /// mmap call no matter how much physical RAM the device has.
    ///
    /// Set in the curated catalog only — user-added MLX models default
    /// to `false` and let the runtime's per-shard pre-flight catch the
    /// case (it inspects the on-disk shard layout, which is the
    /// authoritative answer once the model is downloaded).
    ///
    /// Surfaced by `ModelsView` / `ModelInfoSheet` as a "vyžaduje
    /// paid Apple Developer účet" badge so the user sees the
    /// limitation *before* spending bandwidth on the download.
    var requiresLargeMmapAddressing: Bool
    var downloads: Int?
    var likes: Int?

    var sizeFormatted: String {
        guard sizeBytes > 0 else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// Safely extracts the Hugging Face repository ID (e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit")
    /// from the model's `downloadURL`. Returns nil if the URL is not a standard HF repo format.
    var repoId: String? {
        guard format == .mlx else { return nil }
        // mlx://mlx-community/Llama-3.2-1B-Instruct-4bit  →  host=mlx-community, path=/Llama-3.2-1B-Instruct-4bit
        if downloadURL.scheme?.lowercased() == "mlx" {
            guard let host = downloadURL.host, !host.isEmpty else { return nil }
            let path = downloadURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { return nil }
            return "\(host)/\(path)"
        }
        // https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit
        guard let host = downloadURL.host, host.contains("huggingface.co") else { return nil }
        let pathComponents = downloadURL.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else { return nil }
        return "\(pathComponents[0])/\(pathComponents[1])"
    }

    // MARK: - Codable (migration-safe)

    private enum CodingKeys: String, CodingKey {
        case id, displayName, family, parameterCount, quantization
        case sizeBytes, contextLength, downloadURL, sha256
        case installState, recommendedFor, license, isUserAdded
        case backend, format, installedRepoSHA, requiresAuth
        case requiresLargeMmapAddressing
        case downloads, likes
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
        backend: ModelBackend = .mlx,
        format: ModelFormat = .mlx,
        isUserAdded: Bool = false,
        installedRepoSHA: String? = nil,
        requiresAuth: Bool = false,
        requiresLargeMmapAddressing: Bool = false,
        downloads: Int? = nil,
        likes: Int? = nil
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
        self.installedRepoSHA = installedRepoSHA
        self.requiresAuth = requiresAuth
        self.requiresLargeMmapAddressing = requiresLargeMmapAddressing
        self.downloads = downloads
        self.likes = likes
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
        installedRepoSHA = try c.decodeIfPresent(String.self, forKey: .installedRepoSHA)
        requiresAuth  = try c.decodeIfPresent(Bool.self, forKey: .requiresAuth) ?? false
        requiresLargeMmapAddressing = try c.decodeIfPresent(Bool.self, forKey: .requiresLargeMmapAddressing) ?? false
        downloads     = try c.decodeIfPresent(Int.self, forKey: .downloads)
        likes         = try c.decodeIfPresent(Int.self, forKey: .likes)
    }
}

// MARK: - Metadata Types

enum ModelBackend: String, Codable, Sendable {
    case llamaCpp = "llama.cpp"
    case mlx = "mlx"
    /// Apple's Core ML pipeline for Stable Diffusion image generation.
    /// Backed by the vendored `StableDiffusion` Swift package (fork of
    /// apple/ml-stable-diffusion). Different runtime path entirely —
    /// `RoutingRuntime` doesn't dispatch text turns to it; image-only.
    case coreML = "coreml"

    /// Short capitalised label for UI badges and diagnostics (e.g. "MLX" / "GGUF").
    var displayName: String {
        switch self {
        case .mlx:      return "MLX"
        case .llamaCpp: return "GGUF"
        case .coreML:   return "Core ML"
        }
    }

    /// One-sentence rationale shown next to the badge / in the info sheet.
    /// Keeps the answer to "what is this and why does it matter?" close to the
    /// surface so users don't have to leave the screen for a docs page.
    var taglineCZ: String {
        switch self {
        case .mlx:      return "Apple MLX runtime — výchozí v této buildu."
        case .llamaCpp: return "llama.cpp runtime — vyžaduje opt-in build s llama.xcframework."
        case .coreML:   return "Apple Core ML — pro generování obrázků na Neural Engine."
        }
    }
}

enum ModelFormat: String, Codable, Sendable {
    case gguf = "GGUF"
    case mlx = "MLX"
    /// Bundle of `.mlmodelc` directories produced by Apple's
    /// `python_coreml_stable_diffusion` converter. Layout:
    ///   ResourcesDir/
    ///     TextEncoder.mlmodelc/
    ///     Unet.mlmodelc/  (or UnetChunk1+2 for memory-split builds)
    ///     VAEDecoder.mlmodelc/
    ///     vocab.json
    ///     merges.txt
    case coreMLPackage = "CoreML"
}

/// Compile-time map of which runtime backends are linked into this build.
///
/// `MLX` is always linked (it has no native binary dep beyond SPM). `llama.cpp`
/// only links when the project is built with `HOMEHUB_LLAMA_RUNTIME` AND with
/// `llama.xcframework` available; otherwise the runtime sources compile to no-ops
/// and `RoutingRuntime` rejects `.llamaCpp` models with an actionable error.
///
/// **Single source of truth.** Every UI surface that decides "can I let the user
/// pick this?" goes through `LocalModel.isUsableInThisBuild` (see below) which
/// reads from this enum. Avoid sprinkling `#if HOMEHUB_LLAMA_RUNTIME` outside
/// runtime wiring — UI gating is a runtime / data question, not a compile one.
enum RuntimeBackendAvailability {
    static var mlxAvailable: Bool { true }

    static var llamaCppAvailable: Bool {
        #if HOMEHUB_LLAMA_RUNTIME
        return true
        #else
        return false
        #endif
    }

    /// Core ML SD compiles in when the `StableDiffusion` Swift package
    /// resolves. The actual runtime file gates the implementation with
    /// `#if canImport(StableDiffusion)` so a build without the package
    /// still links — calls just return `notImplemented`.
    static var coreMLAvailable: Bool {
        #if canImport(StableDiffusion)
        return true
        #else
        return false
        #endif
    }

    static func isAvailable(_ backend: ModelBackend) -> Bool {
        switch backend {
        case .mlx:      return mlxAvailable
        case .llamaCpp: return llamaCppAvailable
        case .coreML:   return coreMLAvailable
        }
    }

    /// User-facing one-liner describing the set of runtimes this build supports.
    /// Surfaced in the developer diagnostics screen.
    static var summary: String {
        if llamaCppAvailable {
            return "MLX (default) + llama.cpp opt-in"
        }
        return "MLX-only (llama.cpp opt-in disabled)"
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

// MARK: - Build-time runtime availability

extension LocalModel {
    /// True if the current build can actually load and run this model.
    ///
    /// MLX models are always usable. GGUF / llama.cpp models require the
    /// optional `HOMEHUB_LLAMA_RUNTIME` build flag — without it the routing
    /// layer would throw `.backendUnavailable(...)` on load. Use this to gate
    /// UI affordances (selection, "Load" button, default picks) so the user
    /// never gets pushed into a path the build can't satisfy.
    var isUsableInThisBuild: Bool {
        RuntimeBackendAvailability.isAvailable(backend)
    }

    /// Short actionable hint shown next to a disabled affordance explaining
    /// why this model can't be loaded in the current build.
    /// Returns `nil` when the model IS usable (no message needed).
    var unavailableReason: String? {
        guard !isUsableInThisBuild else { return nil }
        switch backend {
        case .llamaCpp:
            return "GGUF / llama.cpp model — vyžaduje opt-in build s llama.xcframework. Viz README."
        case .mlx:
            // Should never happen — MLX is always available in this build.
            return "MLX runtime is unexpectedly unavailable in this build."
        case .coreML:
            // Fires when the `StableDiffusion` Swift package isn't
            // linked into the build (someone stripped it from
            // project.yml to shrink binary size). The runtime file
            // still compiles thanks to `#if canImport(StableDiffusion)`
            // — every call just throws `notImplemented`.
            return "Core ML Stable Diffusion modul není v tomto buildu nalinkovaný. Generování obrázků nebude fungovat."
        }
    }
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
        downloadURL: URL(static: "https://huggingface.co/mlx-community/mock-model"),
        installState: .notInstalled,
        recommendedFor: [.iPhone, .iPadMSeries],
        license: "Llama 3",
        backend: .mlx,
        format: .mlx,
        isUserAdded: false
    )
}
