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
    /// Only reached when `HOMEHUB_HAS_KERNEL_ENTITLEMENTS=YES` is set — without
    /// the `extended-virtual-addressing` entitlement, iOS sandboxes mmap to
    /// ≤ 2 GB contiguous blocks regardless of physical RAM, making >2 GB models
    /// fail at load time and rendering the generous profile dangerous to use.
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
    /// Always 99 (full Metal GPU) for stability — keeping layers on CPU increases
    /// memory bandwidth pressure and paradoxically raises OOM risk on tight devices.
    public let maxGPULayers: Int

    /// Safe history token budget for multi-turn conversations.
    /// Consumed by `PromptTokenBudgeter.trimHistory()`.
    public let safeHistoryTokenBudget: Int

    /// Maximum image token budget for multimodal models.
    /// Without `increased-memory-limit`, image tensors easily exhaust the sandbox.
    /// 70 tokens ≈ 336×336 px — enough for visual grounding, low memory cost.
    public let imageTokenBudget: Int

    /// Whether the app was built with kernel entitlements active.
    /// Surfaced here for diagnostics / UI warnings about model size limits.
    public let hasKernelEntitlements: Bool
}

/// Singleton provider for device memory detection and LLM parameter tuning.
///
/// Reads physical RAM at app startup via `ProcessInfo.physicalMemory`,
/// classifies into memory tiers, and returns calibrated profiles for the
/// running device. Profiles are immutable and safe to read from any thread.
///
/// ## Kernel entitlement awareness
///
/// Without `com.apple.developer.kernel.extended-virtual-addressing`, iOS limits
/// contiguous mmap allocations to ~2 GB. Any model file larger than that will
/// crash at load time. This provider detects the entitlement state at compile
/// time via the `HOMEHUB_HAS_KERNEL_ENTITLEMENTS` build flag:
///
/// - **Flag absent / NO** (default, free developer account): tier is capped at
///   `moderate`, n_ctx ≤ 2048, MLX cache ≤ 50 MB, image budget = 70 tokens.
///   Models ≤ 2 GB load safely; larger models show a size warning in the UI.
///
/// - **Flag set to YES** (paid developer + entitlements in provisioning profile):
///   full tier detection applies, generous profile unlocked on flagship devices.
///
/// To enable: add `HOMEHUB_HAS_KERNEL_ENTITLEMENTS = YES` to `LocalOverride.xcconfig`
/// after adding the capabilities in Xcode (see KERNEL_ENTITLEMENTS.md).
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

        let entitlementNote = self.profile.hasKernelEntitlements
            ? "kernel entitlements ACTIVE (generous tier unlocked)"
            : "no kernel entitlements — sandboxed mode (tier capped at moderate)"

        Self.log.info("""
        Device memory profile:
          physical: \(Int(physicalRAM / 1_000_000_000))GB
          usable: \(Int(usableRAM / 1_000_000_000))GB
          tier: \(tier.label)
          context: \(self.profile.contextWindowTokens) tokens
          batch: \(self.profile.batchSizeTokens) tokens
          ubatch: \(self.profile.microBatchSizeTokens) tokens
          mlx cache: \(Int(self.profile.mlxGPUCacheLimitBytes / 1024 / 1024))MB
          image budget: \(self.profile.imageTokenBudget) tokens
          \(entitlementNote)
        """)
    }

    // MARK: - Kernel entitlement detection

    /// True when this binary was compiled with `HOMEHUB_HAS_KERNEL_ENTITLEMENTS=YES`.
    ///
    /// A compile-time constant mirrors what is actually embedded in the provisioning
    /// profile — runtime mmap probes are unreliable because iOS may succeed on small
    /// reservations but still crash on model-sized (3–8 GB) allocations.
    static let kernelEntitlementsEnabled: Bool = {
        #if HOMEHUB_HAS_KERNEL_ENTITLEMENTS
        return true
        #else
        return false
        #endif
    }()

    /// Largest single contiguous `mmap` (one `*.safetensors` shard) the iOS
    /// sandbox permits WITHOUT the `extended-virtual-addressing` entitlement.
    ///
    /// Single source of truth for the free-account weight-load ceiling. Used
    /// by `MLXRuntime`'s per-shard pre-flight to refuse oversized models, and
    /// by the catalog-consistency test to guarantee no iPhone-recommended MLX
    /// model ships a shard the free build can't load. ~2 GB is the documented
    /// limit; 2.1 GB is used as the operative threshold (a model whose single
    /// shard exceeds this is rejected before weight map-in).
    ///
    /// Irrelevant once `kernelEntitlementsEnabled == true` — with the
    /// entitlement, contiguous mappings are bounded only by physical RAM.
    public static let sandboxedSingleShardCeilingBytes: Int64 = 2_100_000_000

    // MARK: - Memory estimation

    /// Estimate usable RAM for user-space processes.
    ///
    /// iOS reserves ~20–30% for kernel, buffers, and system processes.
    private static func estimateUsableRAM(physicalRAM: UInt64) -> UInt64 {
        return UInt64(Double(physicalRAM) * 0.75) // 25% reserved for OS
    }

    // MARK: - Memory tier classification

    /// Classify device into memory tier based on usable RAM.
    ///
    /// Without kernel entitlements the generous tier is suppressed: even if
    /// physical RAM would qualify, mmap constraints make it unsafe to use the
    /// larger context / batch parameters associated with that tier.
    private static func classifyMemoryTier(usableRAM: UInt64) -> MemoryTier {
        let gb = Double(usableRAM) / 1_000_000_000.0
        let raw: MemoryTier
        if gb <= 3.5 {
            raw = .tight
        } else if gb <= 7.0 {
            raw = .moderate
        } else {
            raw = .generous
        }

        // Cap at moderate when entitlements are absent.
        // Without extended-virtual-addressing, contiguous mmap allocations are
        // limited to ~2 GB. A model that physically fits in RAM can still fail
        // to load if its weight file exceeds that threshold.
        if !kernelEntitlementsEnabled, raw == .generous {
            return .moderate
        }
        return raw
    }

    // MARK: - Profile builder

    /// Construct a calibrated profile for the detected memory tier.
    private static func buildProfile(tier: MemoryTier, usableRAM: UInt64) -> DeviceMemoryProfile {
        let entitlements = kernelEntitlementsEnabled
        switch tier {
        case .tight:
            // iPhone SE, iPhone 11: ~3–4 GB usable.
            // Gemini recommendation: n_ctx 600–1024, n_batch 256, image_tokens 70.
            return DeviceMemoryProfile(
                tier: tier,
                usableRAMBytes: usableRAM,
                contextWindowTokens: 1024,
                batchSizeTokens: 256,           // Gemini: 256 for all sandboxed devices
                microBatchSizeTokens: 32,        // Tiny: minimizes latency variance on constrained RAM
                mlxGPUCacheLimitBytes: 25 * 1024 * 1024,  // 25 MB (strict)
                maxGPULayers: 99,                // Always full GPU — CPU layers raise memory bandwidth
                safeHistoryTokenBudget: 600,
                imageTokenBudget: 70,            // Gemini: 70 tokens prevents multimodal OOM
                hasKernelEntitlements: entitlements
            )

        case .moderate:
            // iPhone 13–15 base, iPad Air, *or* iPhone 16 Pro without entitlements.
            // 4096 context: KV cache for 4K tokens is ~200–400 MB (well under the
            // 2 GB sandboxed mmap limit); the limit applies to model weight files,
            // not to KV allocations. Matches what Enclave AI uses on the same hardware.
            return DeviceMemoryProfile(
                tier: tier,
                usableRAMBytes: usableRAM,
                contextWindowTokens: 4096,
                batchSizeTokens: 256,
                microBatchSizeTokens: 64,        // Sweet spot on Apple Neural Engine
                mlxGPUCacheLimitBytes: 200 * 1024 * 1024,  // 200 MB — 50 MB caused constant buffer eviction during decode
                maxGPULayers: 99,                // Full GPU offload
                safeHistoryTokenBudget: 2800,
                imageTokenBudget: 70,            // conservative even on moderate
                hasKernelEntitlements: entitlements
            )

        case .generous:
            // iPhone 16 Pro / iPad Pro M2+ WITH kernel entitlements only.
            // Tier is never reached without HOMEHUB_HAS_KERNEL_ENTITLEMENTS.
            return DeviceMemoryProfile(
                tier: tier,
                usableRAMBytes: usableRAM,
                contextWindowTokens: 4096,
                batchSizeTokens: 512,
                microBatchSizeTokens: 128,       // Maximize GPU parallelism during decoding
                mlxGPUCacheLimitBytes: 512 * 1024 * 1024,  // 512 MB — kernel entitlements + 8 GB RAM allow aggressive pool
                maxGPULayers: 99,                // Full GPU offload
                safeHistoryTokenBudget: 2800,
                imageTokenBudget: 256,           // Entitlements present: full image quality
                hasKernelEntitlements: true
            )
        }
    }
}
