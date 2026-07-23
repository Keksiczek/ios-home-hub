import Foundation
import Security
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
        let usableRAM = Self.usableRAM(physicalRAM: physicalRAM)
        let tier = Self.classifyMemoryTier(usableRAM: usableRAM)

        self.profile = Self.buildProfile(tier: tier, usableRAM: usableRAM)

        // `os_proc_available_memory()` reflects the *effective* jetsam budget,
        // so it is the empirical cross-check on the entitlement state: on an
        // 8 GB device it reports roughly 3 GB unentitled and ~5 GB entitled.
        // Logged alongside the declared/granted flags so a mismatch between
        // "we think we're entitled" and "the kernel disagrees" is visible in
        // one glance rather than requiring a jetsam report to diagnose.
        let availableMB = Int(os_proc_available_memory() / 1_048_576)

        Self.log.info("""
        Device memory profile:
          physical: \(Int(physicalRAM / 1_000_000_000))GB
          usable: \(Int(usableRAM / 1_000_000_000))GB
          proc budget now: \(availableMB)MB
          tier: \(tier.label)
          context: \(self.profile.contextWindowTokens) tokens
          batch: \(self.profile.batchSizeTokens) tokens
          ubatch: \(self.profile.microBatchSizeTokens) tokens
          mlx cache: \(Int(self.profile.mlxGPUCacheLimitBytes / 1024 / 1024))MB
          image budget: \(self.profile.imageTokenBudget) tokens
          entitlements: \(Self.entitlementDiagnosticSummary, privacy: .public)
        """)
    }

    // MARK: - Kernel entitlement detection

    /// Build-time intent: `true` when compiled with `HOMEHUB_HAS_KERNEL_ENTITLEMENTS`.
    ///
    /// Says only that the *project* declares the entitlements. It cannot say
    /// whether Apple's signing server granted them, which is what actually
    /// determines runtime behaviour.
    public static let kernelEntitlementsDeclared: Bool = {
        #if HOMEHUB_HAS_KERNEL_ENTITLEMENTS
        return true
        #else
        return false
        #endif
    }()

    /// The process's total memory allowance before jetsam kills it, in bytes.
    ///
    /// Derived rather than measured directly, because iOS exposes no API for
    /// "what is my limit". It does expose the two halves:
    ///
    ///   * `os_proc_available_memory()` — bytes still available before termination.
    ///   * `phys_footprint` (from `TASK_VM_INFO`) — bytes already charged to us.
    ///     This is the exact counter jetsam evaluates, which is why it is the
    ///     right one to add back.
    ///
    /// Their sum is the limit, and crucially it is **time-invariant**: as the
    /// app allocates, footprint rises and available falls by the same amount.
    /// That means this can be called at any point in the lifecycle and still
    /// give the same answer — unlike sampling `os_proc_available_memory()`
    /// alone at launch, which would be meaningless once a model is resident.
    ///
    /// Returns `0` when `task_info` fails, which callers treat as "unknown".
    public static func processMemoryLimitBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint) + UInt64(os_proc_available_memory())
    }

    /// Whether the build may load models whose largest single shard exceeds the
    /// sandboxed `mmap` ceiling.
    ///
    /// **Only the declared flag** — deliberately, after an inference attempt was
    /// falsified by device data.
    ///
    /// There is no supported way to read the *granted* entitlement from inside
    /// an iOS app. `SecTaskCopyValueForEntitlement` links but is not declared on
    /// iOS (`SecTask.h` ships macOS-only; compiling against the iOS 26.2 SDK
    /// gives `cannot find 'SecTaskCreateFromSelf' in scope`), and parsing
    /// `embedded.mobileprovision` fails in the case that matters most, because
    /// App Store builds contain no embedded profile.
    ///
    /// An earlier revision therefore inferred the grant from the ratio of the
    /// process memory limit to physical RAM, assuming an unentitled app is held
    /// to 33–40 % of physical RAM. **Device measurement falsified that.** An
    /// unentitled iPhone 16 Pro (iPhone17,1) on iOS 26.5.2 reports 6137 MB
    /// available at launch — 74.9 % of its 8 GB. The ratio test would have said
    /// "granted" on an unentitled device: budgets unlocked without the headroom
    /// behind them, which is exactly the direction that causes the jetsam kills
    /// this work exists to stop.
    ///
    /// The inference is gone, and the two concerns it conflated are kept apart:
    ///
    ///   * `extended-virtual-addressing` governs the **single contiguous mmap
    ///     ceiling** (~2 GB without it). That is a virtual-addressing limit and
    ///     is invisible to any memory measurement, so the declared flag is the
    ///     only thing that can speak to it. Hence this property, whose one
    ///     consumer is the per-shard pre-flight in `MLXRuntime`.
    ///   * `increased-memory-limit` governs **how much memory we may use**,
    ///     which `os_proc_available_memory()` reports directly and exactly.
    ///     Tier selection now reads that measurement rather than inferring
    ///     anything — see `classifyMemoryTier`.
    ///
    /// Measuring the thing that matters beats inferring the flag that implies it.
    public static let kernelEntitlementsEnabled: Bool = kernelEntitlementsDeclared

    /// Human-readable entitlement + budget state for Developer Diagnostics.
    public static var entitlementDiagnosticSummary: String {
        let limitMB = processMemoryLimitBytes() / 1_048_576
        let mmap = kernelEntitlementsDeclared
            ? "large-mmap declared (single shards > 2 GB allowed)"
            : "large-mmap NOT declared (single shards capped at ~2 GB)"
        #if targetEnvironment(simulator)
        return "\(mmap); Simulator inherits host limits, measured \(limitMB) MB"
        #else
        return "\(mmap); measured process limit \(limitMB) MB"
        #endif
    }

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

    /// Memory this process may actually use, in bytes.
    ///
    /// Prefers the **measured** limit (`phys_footprint + os_proc_available_memory()`,
    /// see `processMemoryLimitBytes`) and falls back to a 0.75 × physical-RAM
    /// estimate only when `task_info` fails.
    ///
    /// The measurement is strictly better than the estimate because it accounts
    /// for everything the estimate cannot: the iOS version's default policy, the
    /// kernel entitlements, the device's current memory pressure, and whatever
    /// else the OS is doing. On an iPhone 16 Pro running iOS 26.5.2 the two
    /// happen to agree closely (measured ≈ 6.3 GB vs. estimated 6.44 GB), but
    /// that agreement is a coincidence of this iOS version — the estimate was
    /// written when the ratio was very different, and it will drift again.
    private static func usableRAM(physicalRAM: UInt64) -> UInt64 {
        let measured = processMemoryLimitBytes()
        guard measured > 0 else {
            log.notice("task_info unavailable — falling back to 0.75 × physical RAM estimate")
            return UInt64(Double(physicalRAM) * 0.75)
        }
        return measured
    }

    // MARK: - Memory tier classification

    /// Classify the device into a memory tier from the **measured** process
    /// memory limit.
    ///
    /// ## Why the thresholds moved, and why the entitlement cap is gone
    ///
    /// The previous thresholds (`≤3.5 GB` tight, `≤7.0 GB` moderate, else
    /// generous) were applied to `physicalRAM × 0.75`. On an 8 GB iPhone that
    /// yields 6.44 GB, which lands in `moderate` — so **the generous tier was
    /// unreachable on every 8 GB iPhone and 8 GB iPad regardless of
    /// entitlements**. Reaching it needed > 9.3 GB of physical RAM, i.e. only
    /// the 12/16 GB iPads. That was almost certainly not intended: the tier's
    /// own comment names "iPhone 16 Pro / iPad Pro M2+" as its target.
    ///
    /// The old code additionally forced `generous → moderate` whenever the
    /// kernel entitlements were absent. That conflated two unrelated limits.
    /// The mmap ceiling is about *virtual addressing* and is enforced where it
    /// belongs — the per-shard pre-flight in `MLXRuntime`, which still gates on
    /// `kernelEntitlementsEnabled`. The tier is about *how much memory we may
    /// use*, and `os_proc_available_memory()` answers that directly. Suppressing
    /// the tier as a proxy for the mmap limit punished a device that genuinely
    /// had the headroom.
    ///
    /// Thresholds are set from what the tiers must actually accommodate —
    /// weights plus KV cache plus Metal scratch:
    ///
    /// | Tier | Measured limit | Fits |
    /// |---|---|---|
    /// | `.tight` | < 3 GB | ≤ 2B 4-bit (~1.5 GB) |
    /// | `.moderate` | 3 – 5.5 GB | 3B–4B 4-bit (~2–3 GB) |
    /// | `.generous` | ≥ 5.5 GB | 7B–8B 4-bit (~4.5 GB) + full KV |
    ///
    /// Measured reference points: iPhone 16 Pro / iOS 26.5.2, no entitlements —
    /// 6137 MB available at launch, so ≈ 6.3 GB limit → `.generous`.
    private static func classifyMemoryTier(usableRAM: UInt64) -> MemoryTier {
        let gb = Double(usableRAM) / 1_000_000_000.0
        if gb < 3.0 {
            return .tight
        } else if gb < 5.5 {
            return .moderate
        } else {
            return .generous
        }
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
            // Devices whose MEASURED process limit is ≥ 5.5 GB: iPhone 16/17 Pro,
            // iPad M-series, and anything else the OS is that generous with.
            //
            // No longer conditioned on the kernel entitlements. The tier is
            // about how much memory we may use, which is measured directly; the
            // entitlements govern the single-mmap ceiling, which is enforced in
            // `MLXRuntime`'s per-shard pre-flight where it belongs. Gating the
            // tier on the entitlement used to punish a device that genuinely had
            // the headroom — and on an 8 GB iPhone the old physical-RAM
            // thresholds made this tier unreachable either way.
            //
            // ## Why the context window is 8192 here and not 4096
            //
            // It used to be 4096 — identical to the moderate tier — while
            // `ModelCapabilityProfile.dynamicHistoryBudget` scaled the history
            // budget 2.0× on this tier. That made the numbers mutually
            // inconsistent: on the llama family the generous budget is 2800
            // history + 1024 `generationReserveTokens` + a 600–2500 token system
            // prompt, which can reach ~6300 — well past the 4096 that
            // `ModelCatalogService.adjustContextLength` clamped every model to.
            //
            // Nothing caught the overrun, because MLX has no secondary clamp:
            // `ChatSession` is constructed without an `n_ctx` parameter (unlike
            // the llama.cpp path, which passes one to `LlamaContextHandle`), so
            // `safeHistoryTokenBudget` was the *only* real bound on assembled
            // prompt size. 8192 makes the declared ceiling match what the rest
            // of the budgeting already permits, instead of asserting a limit
            // nothing enforces.
            //
            // This does not itself allocate anything. MLX grows the KV cache
            // with the tokens actually present, so the memory cost is driven by
            // `safeHistoryTokenBudget`, which is unchanged. See the invariant
            // check in `ModelCapabilityProfile.dynamicHistoryBudget`.
            return DeviceMemoryProfile(
                tier: tier,
                usableRAMBytes: usableRAM,
                contextWindowTokens: 8192,
                batchSizeTokens: 512,
                microBatchSizeTokens: 128,       // Maximize GPU parallelism during decoding
                mlxGPUCacheLimitBytes: 512 * 1024 * 1024,  // 512 MB — ≥5.5 GB measured headroom allows an aggressive pool
                maxGPULayers: 99,                // Full GPU offload
                safeHistoryTokenBudget: 2800,
                // Image tensors are a headroom cost, not an addressing one, so
                // this follows the measured tier rather than the entitlement.
                imageTokenBudget: 256,
                hasKernelEntitlements: entitlements
            )
        }
    }
}
