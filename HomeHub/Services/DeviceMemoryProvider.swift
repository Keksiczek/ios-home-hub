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
        let usableRAM = Self.estimateUsableRAM(physicalRAM: physicalRAM)
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

    /// Fraction of physical RAM above which the process limit can only be
    /// explained by `increased-memory-limit` being active.
    ///
    /// Measured behaviour on current iOS: an unentitled app is held to roughly
    /// 33–40 % of physical RAM (≈3 GB on an 8 GB iPhone), while an entitled one
    /// reaches roughly 55–75 % (≈5 GB on the same device). The two bands are
    /// wide apart, so 0.48 sits comfortably in the gap and tolerates a fair
    /// amount of per-device and per-iOS-version variation on both sides.
    private static let entitledLimitRatioThreshold = 0.48

    /// Whether the kernel is actually granting the larger allowance.
    ///
    /// This is an inference from the effective limit, not a read of the code
    /// signature. iOS does not expose `SecTaskCopyValueForEntitlement` in its
    /// public SDK (the header ships on macOS only), and the other common trick
    /// — parsing `embedded.mobileprovision` — does not work for the case that
    /// matters most here, because App Store builds have no embedded profile.
    /// The effective limit is the thing we actually care about anyway: it is
    /// what jetsam enforces, whatever the signature happens to say.
    ///
    /// This closes the failure mode the compile-time flag alone cannot see.
    /// Apple's signing server **silently strips** restricted entitlements from
    /// builds signed by a team lacking the capability: the `.entitlements` file
    /// still lists them, the compile flag is still set, and the binary runs
    /// believing it has ~5 GB of headroom — then jetsams the moment a large
    /// model maps in. That happens with a free Apple ID, a provisioning profile
    /// generated before the capability was added, and re-signed builds.
    ///
    /// Returns `false` when the limit cannot be determined — an unknown state
    /// is treated as unentitled, which is the safe direction.
    public static let kernelEntitlementsGranted: Bool = {
        let limit = processMemoryLimitBytes()
        guard limit > 0 else {
            log.error("Entitlement check: task_info failed — assuming unentitled")
            return false
        }
        let physical = UInt64(ProcessInfo.processInfo.physicalMemory)
        guard physical > 0 else { return false }
        let ratio = Double(limit) / Double(physical)
        log.info("""
        Entitlement check: process limit \(limit / 1_048_576) MB of \
        \(physical / 1_048_576) MB physical (ratio \(String(format: "%.2f", ratio)), \
        threshold \(String(format: "%.2f", entitledLimitRatioThreshold)))
        """)
        return ratio >= entitledLimitRatioThreshold
    }()

    /// The operative answer used by every memory budget in the app: the
    /// entitlements were declared at build time **and** the kernel is honouring
    /// them.
    ///
    /// Requiring both is deliberate. The compile flag alone over-promises
    /// (stripped entitlements). The runtime signal alone would let a build that
    /// never declared the capability opportunistically use budgets it was never
    /// tested against — and would misfire on a device whose limit happens to sit
    /// near the threshold for unrelated reasons.
    public static let kernelEntitlementsEnabled: Bool = {
        // Simulator processes inherit the host Mac's memory limits, so the
        // ratio test is meaningless there — it would report "entitled" on any
        // Mac with more RAM than the simulated device. Honour declared intent
        // instead, so tier-dependent code paths still get exercised in
        // development and in the simulator-hosted test suite.
        #if targetEnvironment(simulator)
        return kernelEntitlementsDeclared
        #else
        return kernelEntitlementsDeclared && kernelEntitlementsGranted
        #endif
    }()

    /// Human-readable entitlement state for the Developer Diagnostics screen.
    ///
    /// Distinguishes the states that call for different action: "declared but
    /// not granted" is a signing misconfiguration the developer can fix in
    /// minutes, whereas "not declared" is a deliberate build choice.
    public static var entitlementDiagnosticSummary: String {
        #if targetEnvironment(simulator)
        return kernelEntitlementsDeclared
            ? "declared; not verifiable on Simulator (honoured for development)"
            : "not declared — conservative memory budgets"
        #else
        let limitMB = processMemoryLimitBytes() / 1_048_576
        switch (kernelEntitlementsDeclared, kernelEntitlementsGranted) {
        case (true, true):
            return "active — process limit \(limitMB) MB, generous memory budgets"
        case (true, false):
            return "DECLARED BUT NOT GRANTED — process limit only \(limitMB) MB. "
                 + "Regenerate the provisioning profile with both kernel capabilities."
        case (false, true):
            return "kernel allows \(limitMB) MB but the build did not declare the "
                 + "entitlements — using conservative budgets"
        case (false, false):
            return "not declared — conservative memory budgets (\(limitMB) MB limit)"
        }
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
            // iPhone 16/17 Pro / iPad M-series WITH kernel entitlements only.
            // Tier is never reached unless both the build declares the
            // entitlements and the kernel is honouring them.
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
                mlxGPUCacheLimitBytes: 512 * 1024 * 1024,  // 512 MB — kernel entitlements + 8 GB RAM allow aggressive pool
                maxGPULayers: 99,                // Full GPU offload
                safeHistoryTokenBudget: 2800,
                imageTokenBudget: 256,           // Entitlements present: full image quality
                hasKernelEntitlements: true
            )
        }
    }
}
