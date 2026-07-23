import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Apple Silicon SoC family of the host device.
///
/// Detection is best-effort — based on `hw.machine` (real device) or the
/// `SIMULATOR_MODEL_IDENTIFIER` env var (simulator). New device models that
/// haven't been catalogued here fall through to `.unknown` and are treated
/// as "modern" (no safe-mode constraints applied).
public enum AppleSoCFamily: Sendable, Equatable {
    case aSeriesPre14    // A11 / A12 / A13 — pre-Neural-Engine-v3 generation
    case a14             // iPhone 12 family
    case a15             // iPhone 13 / 14
    case a16             // iPhone 14 Pro / 15
    case a17Pro          // iPhone 15 Pro
    case a18             // iPhone 16 family
    case mSeries         // iPad Pro M1+ / Mac
    case unknown         // unidentified or simulator on a non-Apple-Silicon host

    /// SoCs with documented Scaled-Dot-Product-Attention (SDPA / Flash
    /// Attention) regressions in the Metal Performance Shaders stack.
    /// On these chips the runtime prefers correctness over peak throughput:
    /// no Flash Attention, no aggressive KV-cache reuse, smaller GPU cache.
    ///
    /// Reference: see `Rozbor aplikace iOS Home Hub.md` § Hardwarové regrese
    /// + Apple Developer Forums "Machine Learning & AI" reports on A14.
    var hasKnownSDPARegression: Bool {
        switch self {
        case .aSeriesPre14, .a14: return true
        case .a15, .a16, .a17Pro, .a18, .mSeries, .unknown: return false
        }
    }

    var label: String {
        switch self {
        case .aSeriesPre14: return "Apple A11–A13"
        case .a14:          return "Apple A14"
        case .a15:          return "Apple A15"
        case .a16:          return "Apple A16"
        case .a17Pro:       return "Apple A17 Pro"
        case .a18:          return "Apple A18 (Pro)"
        case .mSeries:      return "Apple M-series"
        case .unknown:      return "Unknown / Simulator"
        }
    }
}

/// Hardware-capability gate for runtime optimisations.
///
/// Centralises the decision "is this device known to have problems with
/// optimisation X?" so individual runtimes don't replicate brittle device
/// string-matching. A single source means we can change the policy in one
/// place when a new iOS release fixes (or breaks) a path.
///
/// ## Why a separate type from `DeviceMemoryProvider`
/// `DeviceMemoryProvider` answers "how much RAM can I spend?". This type
/// answers "which code paths are safe on this silicon?". The two intersect
/// for the MLX GPU cache limit — `safeGPUCacheLimitBytes` returns the
/// smaller of the two budgets — but otherwise they're orthogonal: a 4 GB
/// iPhone 11 (memory-tight + SDPA-regression) and an 8 GB iPad Pro M2
/// (memory-generous + no regression) need very different mitigations even
/// if their RAM-only profile looked similar after sandboxing.
public final class HardwareCapabilities: @unchecked Sendable {

    public static let shared = HardwareCapabilities()

    public let soc: AppleSoCFamily
    public let machineIdentifier: String

    /// `true` when the current SoC is on the regression list. Runtimes
    /// should disable Flash Attention / aggressive Metal pipelines and prefer
    /// the safer (slower) attention path.
    public var safeAttentionMode: Bool { soc.hasKnownSDPARegression }

    /// `true` when Flash Attention can be enabled safely. Negation of
    /// `safeAttentionMode`; named positively so call sites read naturally.
    public var flashAttentionEnabled: Bool { !safeAttentionMode }

    /// Hard ceiling on the MLX GPU cache (bytes) for the current SoC.
    /// Clamps the per-tier value from `DeviceMemoryProvider` down to a
    /// safer value on chips that have shown buffer-allocation pathology.
    ///
    /// Callers should take `min(deviceMemoryProfile.mlxGPUCacheLimitBytes,
    /// safeGPUCacheLimitBytes)` rather than using either value directly.
    ///
    /// ## Why the top tier is entitlement-aware
    ///
    /// This clamp exists to protect against *silicon* pathology, not to ration
    /// memory — that is `DeviceMemoryProvider`'s job, and the `min(...)` at the
    /// call sites is what keeps the two orthogonal. But A18 and M-series have no
    /// known regression (the comment on that line used to read "no SoC-side cap"
    /// while returning a 256 MB cap), so the value was silently acting as a
    /// memory budget for the two chips that need it least.
    ///
    /// The consequence was that the entitled `generous` tier's 512 MB pool could
    /// never take effect: `min(512, 256) == 256` on exactly the iPhone 16/17 Pro
    /// and iPad M-series hardware the tier was written for. Raising the entitled
    /// ceiling to 768 MB keeps this a genuine SoC guard rather than the binding
    /// constraint, and leaves `DeviceMemoryProvider` as the single authority on
    /// how much memory is actually affordable.
    ///
    /// Unentitled builds keep the old 256 MB value — without the raised jetsam
    /// threshold, a larger Metal pool is exactly the wrong trade.
    public var safeGPUCacheLimitBytes: UInt64 {
        switch soc {
        case .aSeriesPre14:     return  16 * 1024 * 1024     // 16 MB — absolute floor
        case .a14:              return  25 * 1024 * 1024     // 25 MB — match tight tier
        case .a15:              return  50 * 1024 * 1024
        case .a16, .a17Pro:     return  96 * 1024 * 1024
        case .a18, .mSeries:
            // Headroom above the generous tier's 512 MB so this stays a guard,
            // not a budget. No known Metal buffer pathology on either family.
            return DeviceMemoryProvider.kernelEntitlementsEnabled
                ? 768 * 1024 * 1024
                : 256 * 1024 * 1024
        case .unknown:          return  50 * 1024 * 1024     // moderate fallback
        }
    }

    /// Suggested upper bound on llama.cpp/MLX prompt batch size for the
    /// current SoC. Smaller batches reduce peak Metal scratch-buffer size,
    /// which is the most common OOM trigger during prompt evaluation on
    /// constrained SoCs.
    public var safeBatchSizeTokens: Int {
        switch soc {
        case .aSeriesPre14, .a14:   return 128
        case .a15:                  return 256
        case .a16, .a17Pro:         return 384
        case .a18, .mSeries:        return 512
        case .unknown:              return 256
        }
    }

    private init() {
        let raw = Self.readMachineIdentifier()
        self.machineIdentifier = raw
        self.soc = Self.classify(machineID: raw)
        let log = Logger(subsystem: "HomeHub", category: "HardwareCapabilities")
        log.info("""
        Hardware capabilities:
          machine: \(raw, privacy: .public)
          soc: \(self.soc.label, privacy: .public)
          safeAttentionMode: \(self.safeAttentionMode, privacy: .public)
          safeGPUCacheLimit: \(Int(self.safeGPUCacheLimitBytes / 1024 / 1024), privacy: .public)MB
          safeBatchSize: \(self.safeBatchSizeTokens, privacy: .public) tokens
        """)
    }

    // MARK: - Detection

    /// Reads `hw.machine` (real device) or `SIMULATOR_MODEL_IDENTIFIER`
    /// (simulator). Returns an empty string on failure — callers fall
    /// through to `.unknown` and incur no extra constraints.
    static func readMachineIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let env = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !env.isEmpty {
            return env
        }
        return "Simulator"
        #else
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
        #endif
    }

    /// Maps a `hw.machine` identifier to a SoC family.
    /// Identifiers come in the form `iPhoneN,M` / `iPadN,M`.
    static func classify(machineID: String) -> AppleSoCFamily {
        // iPad Pro M-series and Mac targets.
        if machineID.hasPrefix("iPad13,") || machineID.hasPrefix("iPad14,")
            || machineID.hasPrefix("iPad15,") || machineID.hasPrefix("iPad16,")
            || machineID.hasPrefix("arm64") || machineID.hasPrefix("Mac") {
            // iPad13,8+ = iPad Pro M1; iPad14,3+ = M2; iPad16,* = M4.
            return .mSeries
        }

        guard machineID.hasPrefix("iPhone") else {
            return .unknown
        }

        // Extract the major version from "iPhoneN,M".
        let body = machineID.dropFirst("iPhone".count)
        guard let commaIdx = body.firstIndex(of: ","),
              let major = Int(body[..<commaIdx]) else {
            return .unknown
        }

        switch major {
        case ..<10:          return .aSeriesPre14   // iPhone 5s..X (A7..A11)
        case 10:             return .aSeriesPre14   // iPhone 8 / X (A11)
        case 11:             return .aSeriesPre14   // iPhone XS / XR (A12)
        case 12:             return .aSeriesPre14   // iPhone 11 (A13)
        case 13:             return .a14            // iPhone 12 family
        case 14:             return .a15            // iPhone 13 / 14
        case 15:             return .a16            // iPhone 14 Pro / 15
        case 16:             return .a17Pro         // iPhone 15 Pro
        case 17:             return .a18            // iPhone 16 family
        default:             return .a18            // newer than catalogued — assume modern
        }
    }
}
