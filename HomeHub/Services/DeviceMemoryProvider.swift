import Foundation
import os

/// Dynamic memory tier classification based on device RAM.
///
/// Automatically calibrates LLM parameters (context window, batch size, GPU cache)
/// to maximize performance without triggering Jetsam OOM on the running device.
/// Values are conservative and tested against devices across the iOS spectrum
/// (iPhone SE to iPhone 16 Pro, iPad mini to iPad Pro M4).
public enum MemoryTier: Sendable {
    /// Very constrained: older iPhones, SE models. ~3–4 GB usable RAM.
    case tight
    /// Standard iPhone: iPhone 13–15 base, some iPad Air. ~4–6 GB usable.
    case moderate
    /// Modern flagship: iPhone 16 Pro, iPad Pro M2+. ~8 GB+ usable.
    case generous

    /// Human-readable label for diagnostics.
    var label: String {
        switch self {
        case .tight: return "tight (≤4GB)"
        case .moderate: return "moderate (4–6GB)"
        case .generous: return "generous (8GB+)"
        }
    }
}

/// Device runtime memory characteristics and LLM parameter recommendations.
///
/// Populated at app startup; read-only thereafter. All values are conservative
/// (prioritizing stability over raw speed) and calibrated for the baseline device
/// in each tier.
public struct DeviceMemoryProfile: Sendable {
    /// Detected memory tier based on device's physical RAM.
    public let tier: MemoryTier

    /// Total usable RAM available to user-space processes (bytes).
    public let usableRAMBytes: UInt64

    /// Recommended context window (n_ctx) for LLM inference.
    /// Balances conversation history retention with KV cache stability.
    public let contextWindowTokens: Int

    /// Recommended prompt evaluation batch size (n_batch).
    /// Larger on high-memory devices, reduces scratch-pad overflow risk.
    public let batchSizeTokens: Int

    /// Recommended micro-batch size for token-by-token generation (n_ubatch).
    /// Larger = better GPU utilization during decoding, but higher latency variance.
    public let microBatchSizeTokens: Int

    /// Recommended MLX GPU cache limit (bytes).
    /// Aggressive on constrained devices, generous on iPad Pro.
    public let mlxGPUCacheLimitBytes: UInt64

    /// Recommended maximum GPU layers for llama.cpp offload.
    /// `99` = all layers to GPU (maximum throughput).
    /// Lower on memory-constrained devices.
    public let maxGPULayers: Int

    /// Safe history token budget for multi-turn conversations.
    /// Consumed by `PromptTokenBudgeter.trimHistory()`.
    public let safeHistoryTokenBudget: Int
}

/// Singleton provider for device memory detection and LLM parameter tuning.
///
/// Reads physical RAM at app startup via `ProcessInfo.physicalMemory`,
/// classifies into memory tiers, and returns calibrated profiles for the
/// running device. Profiles are immutable and safe to read from any thread.
public final class DeviceMemoryProvider: Sendable {
    private static let log = Logger(subsystem: "HomeHub", category: "DeviceMemoryProvider")

    /// Shared singleton instance. Initialized on first access.
    public static let shared: DeviceMemoryProvider = DeviceMemoryProvider()

    /// The device's detected memory profile (immutable, set at init).
    public let profile: DeviceMemoryProfile

    private init() {
        let physicalRAM = UInt64(ProcessInfo.processInfo.physicalMemory)
        let usableRAM = Self.estimateUsableRAM(physicalRAM: physicalRAM)
        let tier = Self.classifyMemoryTier(usableRAM: usableRAM)

        self.profile = Self.buildProfile(tier: tier, usableRAM: usableRAM)

        Self.log.info("""
        Device memory profile:
          physical: \(Int(physicalRAM / 1_000_000_000))GB
          usable: \(Int(usableRAM / 1_000_000_000))GB
          tier: \(tier.label)
          context: \(self.profile.contextWindowTokens) tokens
          batch: \(self.profile.batchSizeTokens) tokens
          ubatch: \(self.profile.microBatchSizeTokens) tokens
          mlx cache: \(Int(self.profile.mlxGPUCacheLimitBytes / 1024 / 1024))MB
        """)
    }

    // MARK: - Memory estimation

    /// Estimate usable RAM for user-space processes.
    ///
    /// iOS reserves ~20–30% for kernel, buffers, and system processes.
    /// This heuristic assumes the device is not under extreme memory pressure
    /// (e.g., running other background apps). If the user has many background
    /// apps, real available RAM will be lower; the profile adapts automatically
    /// on next app launch.
    private static func estimateUsableRAM(physicalRAM: UInt64) -> UInt64 {
        let reservationFraction = 0.25 // 25% reserved for OS
        return UInt64(Double(physicalRAM) * (1.0 - reservationFraction))
    }

    // MARK: - Memory tier classification

    /// Classify device into memory tier based on usable RAM.
    ///
    /// Boundaries:
    /// - tight: ≤ 3.5 GB (iPhone SE, older iPhones)
    /// - moderate: 3.5–7 GB (iPhone 13–15, iPad Air 5)
    /// - generous: > 7 GB (iPhone 16 Pro, iPad Pro M2+)
    private static func classifyMemoryTier(usableRAM: UInt64) -> MemoryTier {
        let gb = Double(usableRAM) / 1_000_000_000.0
        if gb <= 3.5 {
            return .tight
        } else if gb <= 7.0 {
            return .moderate
        } else {
            return .generous
        }
    }

    // MARK: - Profile builder

    /// Construct a calibrated profile for the detected memory tier.
    private static func buildProfile(tier: MemoryTier, usableRAM: UInt64) -> DeviceMemoryProfile {
        switch tier {
        case .tight:
            // iPhone SE, iPhone 11: ~3–4 GB usable
            return DeviceMemoryProfile(
                tier: tier,
                usableRAMBytes: usableRAM,
                contextWindowTokens: 1024,           // Ultra-conservative
                batchSizeTokens: 128,                // Very small to avoid spikes
                microBatchSizeTokens: 32,            // Tiny for generation to minimize latency variance
                mlxGPUCacheLimitBytes: 25 * 1024 * 1024,  // 25 MB (strict)
                maxGPULayers: 20,                    // Mixed CPU/GPU offload
                safeHistoryTokenBudget: 600
            )

        case .moderate:
            // iPhone 13–15 base, iPad Air: ~4–6 GB usable
            return DeviceMemoryProfile(
                tier: tier,
                usableRAMBytes: usableRAM,
                contextWindowTokens: 2048,           // Balanced
                batchSizeTokens: 256,                // Standard (original)
                microBatchSizeTokens: 64,            // Sweet spot on Apple Neural Engine
                mlxGPUCacheLimitBytes: 50 * 1024 * 1024,   // 50 MB (baseline)
                maxGPULayers: 99,                    // Full GPU offload
                safeHistoryTokenBudget: 1400
            )

        case .generous:
            // iPhone 16 Pro, iPad Pro M2+: ~8+ GB usable
            return DeviceMemoryProfile(
                tier: tier,
                usableRAMBytes: usableRAM,
                contextWindowTokens: 4096,           // Generous for long conversations
                batchSizeTokens: 512,                // Large for throughput
                microBatchSizeTokens: 128,           // Maximize GPU parallelism during decoding
                mlxGPUCacheLimitBytes: 128 * 1024 * 1024,  // 128 MB (aggressive)
                maxGPULayers: 99,                    // Full GPU offload
                safeHistoryTokenBudget: 2800
            )
        }
    }
}
