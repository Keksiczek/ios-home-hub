import Foundation
import SwiftUI
import os

/// The list of models the user can pick from. In v1 the curated catalog is
/// hard-coded and vetted for iPhone 16 Pro / M-series iPad. User-added models
/// (via "Add from URL") are persisted in `user-models.json` alongside the
/// catalog and merged at launch.
///
/// Context windows are dynamically adjusted at init time based on device memory
/// (iPhone SE vs. iPhone 16 Pro vs. iPad Pro). See `DeviceMemoryProvider`.
@MainActor
final class ModelCatalogService: ObservableObject {
    @Published private(set) var models: [LocalModel]

    /// Per-model GGUF header snapshot. Populated on:
    ///   1. successful GGUF install (post-finalize in ModelDownloadService), and
    ///   2. disk reconcile at app launch (so an already-installed GGUF picks up
    ///      its metadata even though no install event fires).
    ///
    /// Read by the runtime to choose chat-template source + effective context
    /// length, and by `ModelInfoSheet` to surface metadata to the user.
    /// Missing entries are normal — callers fall back to catalog defaults.
    @Published private(set) var ggufMetadata: [String: GGUFModelMetadata] = [:]

    init(models: [LocalModel] = ModelCatalog.curated) {
        let memoryProfile = DeviceMemoryProvider.shared.profile
        // Adjust all models' context windows to device memory tier.
        // This ensures iPhone SE doesn't OOM and iPhone 16 Pro maximizes conversation length.
        self.models = models.map { model in
            var adjusted = model
            adjusted.contextLength = Self.adjustContextLength(
                base: model.contextLength,
                family: model.family,
                recommendedFor: model.recommendedFor,
                memoryProfile: memoryProfile
            )
            return adjusted
        }
    }

    func model(withID id: String) -> LocalModel? {
        models.first { $0.id == id }
    }

    func update(_ model: LocalModel) {
        if let idx = models.firstIndex(where: { $0.id == model.id }) {
            models[idx] = model
        } else {
            models.append(model)
        }
    }

    func setInstallState(_ state: ModelInstallState, for modelID: String) {
        guard let idx = models.firstIndex(where: { $0.id == modelID }) else { return }
        models[idx].installState = state
    }

    /// Pins the upstream commit SHA of an MLX repository at the moment
    /// of its last successful install. Persisted to user-models.json
    /// (no-op for curated models — those are write-through to the
    /// in-memory copy only and a future `versionMismatchAvailable`
    /// banner can still observe them).
    ///
    /// Pair this with `HFModelManifest.sha` after each manifest fetch
    /// to detect that upstream has moved while a cached install is
    /// still pinned to an older commit. Use `installedRepoSHA(for:)`
    /// to read the pin back from the catalog.
    func setInstalledRepoSHA(_ sha: String?, for modelID: String) {
        guard let idx = models.firstIndex(where: { $0.id == modelID }) else { return }
        guard models[idx].installedRepoSHA != sha else { return }
        models[idx].installedRepoSHA = sha
        // Only user-added models go through user-models.json. Curated
        // models live in memory only — their pin is implicitly reset
        // on every cold launch, which is fine for the v1 update-
        // detection UX (we only need the pin to be authoritative
        // across the lifetime of the running session).
        if models[idx].isUserAdded {
            saveUserModels()
        }
    }

    /// Read accessor matching the writer above. Returns `nil` when
    /// the model has never been installed via the SHA-pinning path
    /// (e.g. installed in an older app version).
    func installedRepoSHA(for modelID: String) -> String? {
        models.first(where: { $0.id == modelID })?.installedRepoSHA
    }

    // MARK: - GGUF metadata cache

    /// Reads + caches the header for a freshly-installed GGUF file. No-op
    /// for non-GGUF formats (MLX models get their metadata from the
    /// tokenizer snapshot at load time, not here). Safe to call repeatedly:
    /// re-reads the same file and overwrites the cache entry.
    func cacheGGUFMetadata(for modelID: String, fileURL: URL) {
        guard let model = model(withID: modelID), model.format == .gguf else { return }
        if let meta = GGUFModelMetadata.read(at: fileURL) {
            ggufMetadata[modelID] = meta
        } else {
            // Failure already logged inside GGUFModelMetadata.read — drop
            // any stale entry so the UI doesn't report old metadata for a
            // file the user just re-downloaded.
            ggufMetadata.removeValue(forKey: modelID)
        }
    }

    /// Returns the cached metadata if known.
    func metadata(for modelID: String) -> GGUFModelMetadata? {
        ggufMetadata[modelID]
    }

    /// Catalog-aware effective context length for `modelID`.
    /// Picks the smaller of the catalog's per-device-adjusted value and
    /// the model's declared native context (when known) so the runtime
    /// never exceeds either bound.
    func effectiveContextLength(for modelID: String) -> Int {
        guard let model = model(withID: modelID) else { return 2048 }
        if let metaCtx = ggufMetadata[modelID]?.contextLength {
            return min(model.contextLength, metaCtx)
        }
        return model.contextLength
    }

    var recommendedStarter: LocalModel {
        // Selection priority (each tier matches the previous tier's intent
        // with a more permissive filter, so an upstream rename / missing ID
        // can't strand onboarding on a non-MLX entry):
        //   1. MLX + iPhone-safe + usable + a STRONG instruction follower
        //   2. MLX + iPhone-safe + usable (any strength)
        //   3. Any MLX + usable
        //   4. Any usable model
        //   5. Hard fallback: catalog[0] (only reached if the catalog has
        //      no usable model at all — guarded against by the ≥ 2 MLX
        //      entries validator check, which runs on every PR).
        //
        // Tier 1 exists because onboarding installs this model, and a weak
        // instruction follower (≤2B params) forces `PromptAssemblyService` into
        // lean mode — dropping recall, episodes and file excerpts — so a first
        // impression made on a weak default understates what the app can do.
        //
        // It is a *predicate*, not an ordering convention, deliberately. This
        // used to be "whatever iPhone-safe MLX model appears first in the
        // array", which meant inserting a new small model near the top silently
        // changed the onboarding default. That is an invisible contract; adding
        // a modern 1.7B model tripped it immediately, and only the catalog
        // consistency test caught it.
        if let m = models.first(where: {
            $0.backend == .mlx
                && $0.recommendedFor.contains(.iPhone)
                && $0.isUsableInThisBuild
                && !ModelCapabilityProfile.resolve(
                    family: $0.family,
                    parameterCount: $0.parameterCount,
                    contextLength: $0.contextLength
                ).isWeakInstructionFollower
        }) { return m }
        if let m = models.first(where: {
            $0.backend == .mlx
                && $0.recommendedFor.contains(.iPhone)
                && $0.isUsableInThisBuild
        }) { return m }
        if let m = models.first(where: { $0.backend == .mlx && $0.isUsableInThisBuild }) { return m }
        if let m = models.first(where: \.isUsableInThisBuild) { return m }
        return models[0]
    }

    /// Smallest iPhone-safe MLX model for smoke-testing the default runtime.
    /// Falls back through the same priority ladder as `recommendedStarter`.
    var iPhoneSmokeTestModel: LocalModel {
        if let m = models.first(where: {
            $0.backend == .mlx
                && $0.recommendedFor.contains(.iPhone)
                && $0.isUsableInThisBuild
        }) { return m }
        if let m = models.first(where: { $0.backend == .mlx && $0.isUsableInThisBuild }) { return m }
        return recommendedStarter
    }

    /// Returns `true` when `model` is recommended for iPad M-series only
    /// and is therefore likely to OOM or be very slow on an iPhone.
    func isIPadOnly(_ model: LocalModel) -> Bool {
        !model.recommendedFor.contains(.iPhone)
    }

    // MARK: - Dynamic context adjustment

    /// Adjust model context window based on device memory tier.
    ///
    /// Rules:
    /// - iPhone SE / tight memory: 1024 (ultra-conservative)
    /// - iPhone 13–15 / moderate: multiply by 1.0 (keep static values)
    /// - iPhone 16 Pro / generous: multiply by 2.0 (maximize for long conversations)
    /// - iPad models: always use generous tier allocation
    ///
    /// Ensures Jetsam doesn't OOM old devices while maximizing conversation
    /// length on modern flagships.
    static func adjustContextLength(
        base: Int,
        family: String,
        recommendedFor: [DeviceClass],
        memoryProfile: DeviceMemoryProfile
    ) -> Int {
        // Cap at the device tier limit, but never exceed what the model
        // architecture supports. Avoids both over-capping (Gemma 3n 4096→2048)
        // and over-assigning (SmolLM2 1024→2048).
        return min(base, memoryProfile.contextWindowTokens)
    }

    // MARK: - Build-availability filtered views

    /// All catalog entries the current build can actually load. UI surfaces
    /// that need to answer "do we have any usable models?" (empty state,
    /// onboarding fallback) should query this instead of `models` directly.
    var usableModels: [LocalModel] {
        models.filter(\.isUsableInThisBuild)
    }

    /// Catalog entries that require a backend not linked into this build —
    /// surfaced as disabled rows with an opt-in hint, not as load actions.
    var unusableModels: [LocalModel] {
        models.filter { !$0.isUsableInThisBuild }
    }

    // MARK: - User-added model management

    /// Adds a user-defined model to the catalog and saves to disk.
    func addUserModel(_ model: LocalModel) {
        guard !models.contains(where: { $0.id == model.id }) else { return }
        models.append(model)
        saveUserModels()
    }

    /// Removes a user-added model from the catalog and saves to disk.
    func removeUserModel(id: String) {
        models.removeAll { $0.id == id && $0.isUserAdded }
        saveUserModels()
    }

    // MARK: - Disk reconciliation

    /// Reconciles every catalog model's `installState` against actual files on
    /// disk. Must be called at app launch (in `AppContainer.bootstrap()`) before
    /// `autoLoadSelectedModel()` so the UI and runtime never see stale state.
    ///
    /// Rules:
    /// - File exists + valid GGUF → `.installed(localURL:)`
    /// - File absent or stub/invalid → `.notInstalled`
    /// - In-flight `.downloading` states are left untouched (coordinator owns those).
    func reconcileInstallStates(localModels: LocalModelService) async {
        let installedGGUF = await localModels.installedModelIDs()
        let mlxStates = await localModels.mlxCacheStates(catalogModels: models)

        for idx in models.indices {
            let model = models[idx]
            // Don't disturb an actively-tracked download.
            if case .downloading = model.installState { continue }

            if model.format == .mlx {
                // Phase 3 Refinement: Tri-state logic mapping
                // We map .ready to .installed, and safely map .partial or .missing to .notInstalled
                // because the UI lacks an externally-managed .partial progress state.
                if let state = mlxStates[model.id], state == .ready {
                    let localURL = await localModels.resolvedMLXCacheURL(for: model.repoId ?? "")
                    models[idx].installState = .installed(localURL: localURL)
                    // Promote a freshly-installed user-added MLX model out
                    // of the generic "Custom" family so the chat-template
                    // fallback in `SwiftTransformersTokenizerBridge` can
                    // hit the right render path. Only fires when the
                    // family is still the import-time default to avoid
                    // overwriting a value the user (or a future settings
                    // surface) deliberately set.
                    if model.isUserAdded, model.family == "Custom", let repoId = model.repoId {
                        let inspection = await localModels.inspectMLXCache(for: repoId)
                        if let detected = inspection.detectedFamily {
                            models[idx].family = detected
                        }
                    }
                } else {
                    if model.installState != .notInstalled {
                        models[idx].installState = .notInstalled
                    }
                }
            } else {
                if installedGGUF.contains(model.id) {
                    let localURL = await localModels.localURL(for: model.id)
                    models[idx].installState = .installed(localURL: localURL)
                    // Pre-warm the metadata cache so the first model load doesn't
                    // pay the header parse on the @MainActor and the Model Info
                    // sheet has real values to show before any load is attempted.
                    if ggufMetadata[model.id] == nil {
                        cacheGGUFMetadata(for: model.id, fileURL: localURL)
                    }
                } else {
                    // File gone or invalid — ensure state is consistent.
                    if model.installState != .notInstalled {
                        models[idx].installState = .notInstalled
                    }
                }
            }
        }

        // Persist any family upgrades back to user-models.json so the
        // change survives the next cold launch.
        if models.contains(where: \.isUserAdded) {
            saveUserModels()
        }
    }

    /// Catalog-aware list of MLX cache directories that no longer back
    /// any catalog entry — typically left behind when a user-added
    /// model was deleted while its background download was running, or
    /// when a curated entry was renamed across app versions. Returned
    /// as `org/repo` strings; pair with `LocalModelService.mlxCacheSizeBytes`
    /// + `removeMLXCache` to actually clean them up.
    func orphanedMLXCacheRepos(localModels: LocalModelService) async -> [String] {
        let onDisk = await localModels.enumerateMLXCacheRepos()
        guard !onDisk.isEmpty else { return [] }
        let known = Set(models.compactMap(\.repoId))
        return onDisk.filter { !known.contains($0) }
    }

    // MARK: - User model persistence

    func loadUserModels() {
        guard let url = userModelsFileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LocalModel].self, from: data)
        else { return }

        for var model in decoded {
            guard !models.contains(where: { $0.id == model.id }) else { continue }
            // Always load with .notInstalled; reconcileInstallStates() will fix it up.
            model.installState = .notInstalled
            models.append(model)
        }
    }

    private func saveUserModels() {
        // Encoding happens on @MainActor (cheap — typically 1-4 KB JSON)
        // because we need to snapshot `models` while we still hold the
        // actor. The actual disk write is dispatched to a utility-priority
        // detached Task so we don't block a frame on flash-storage stalls
        // (rare on modern devices, but observed during heavy background
        // workloads). The Task is fire-and-forget: a failed write only
        // costs the next session a stale catalog read, which converges
        // immediately on the next mutation.
        guard let url = userModelsFileURL else { return }
        let userModels = models
            .filter { $0.isUserAdded }
            .map { model -> LocalModel in
                var m = model
                m.installState = .notInstalled   // strip runtime state before persisting
                return m
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(userModels) else { return }
        Task.detached(priority: .utility) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // Persistence failure is non-fatal; the catalog stays in
                // memory and the next mutation will retry the write.
                let log = Logger(subsystem: "HomeHub", category: "ModelCatalogService")
                log.error("saveUserModels failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var userModelsFileURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support.appendingPathComponent("user-models.json")
    }
}

// MARK: - Curated model catalog

enum ModelCatalog {
    /// Curated list of models tested on iPhone 16 Pro and M-series iPad.
    ///
    /// Download URLs point to HuggingFace GGUF repositories (bartowski builds).
    /// SHA-256 hashes are left nil because upstream files may be re-quantised;
    /// populate them after verifying a known-good download to enable integrity
    /// checks.
    static let curated: [LocalModel] = [
        // MARK: Apple Intelligence (built-in, no download)
        //
        // Apple Foundation Models is the only catalog entry whose
        // `installState` is unconditionally `.installed` — there's
        // nothing to download. The runtime path
        // (`AppleFoundationModelsRuntime`) gates actual availability
        // at `load(...)` time via `SystemLanguageModel.default.availability`,
        // surfacing a Czech actionable error if Apple Intelligence
        // isn't enabled on the device.
        //
        // We list it FIRST so onboarding's "pick a model" picker
        // shows it at the top — for iOS 26+ users it's the
        // zero-friction default (instant TTFT, no GB download).
        LocalModel(
            id: "apple-foundation-1",
            displayName: "Apple Intelligence",
            family: "Apple Foundation Models",
            parameterCount: "~3B",        // Apple's published figure for the on-device model
            quantization: "system",       // Apple manages quantisation internally
            sizeBytes: 0,                  // No HomeHub-controlled storage
            contextLength: 4096,           // Apple's documented context for v1 of the on-device model
            // Placeholder URL — `ModelDownloadService` short-circuits
            // for `format == .builtIn` so this is never fetched. We
            // keep a valid URL anyway because `LocalModel.downloadURL`
            // is non-optional. The Apple Intelligence support page
            // surfaces if a user taps "View source" in the model
            // info sheet.
            downloadURL: URL(static: "https://www.apple.com/apple-intelligence/"),
            sha256: nil,
            // Synthetic installState — the runtime layer overrides
            // this for the actual gating decision (see
            // `AppleFoundationModelsRuntime.load(...)`), but UI
            // surfaces honour it as "ready to use" so the user
            // sees the model immediately on iOS 26+.
            installState: .installed(localURL: URL(fileURLWithPath: "/dev/null")),
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Apple — system-managed",
            backend: .appleFoundationModels,
            format: .builtIn
        ),

        // MARK: MLX models (default backend)
        //
        // MLX models are managed by `MLXLMCommon` and downloaded into the Hugging Face
        // cache (`~/.cache/huggingface/hub/`). `LocalModelService` scans that cache and
        // transitions install state to `.installed(localURL:)` once the snapshot is
        // complete.
        //
        // **Curation criteria**:
        // - Hosted under `mlx-community/` (Apple-blessed repo, broadly tested).
        // - 4-bit quantisation that fits on iPhone (≤ ~2.5 GB on disk).
        // - Family already supported by `ChatTemplate` / `ModelCapabilityProfile`.
        //
        // Larger MLX models (Llama 3.1 8B, Qwen 2.5 7B etc.) are intentionally left
        // out of the curated list — they OOM on iPhone. Power users can add them via
        // a future `mlx://` Add-from-URL extension or by editing this list directly.

        // Sizes are the actual `mlx-community` 4-bit weight files reported
        // by Hugging Face (LFS pointer size), rounded *up* to the nearest
        // 50 MB. The disk-space preflight in `ModelDownloadService` adds a
        // 10 % safety margin on top, so a small over-estimate here means
        // the user is never told mid-download "actually we need more room".
        // Llama 3.2 3B — the recommended iPhone starter. Listed FIRST so
        // `recommendedStarter` (which picks the first iPhone-safe MLX entry)
        // selects it instead of the 1B. At 3B it stays a *strong* instruction
        // follower, so `PromptAssemblyService` keeps the full prompt stack
        // (facts, recall, hard rules, tools) instead of collapsing to the
        // lean weak-model path the 1B is forced onto. This is the quality lever
        // that matters most on a free-account iPhone 16 Pro.
        //
        // contextLength 4096 (was 2048): on the MLX path this value does NOT
        // set a hard n_ctx — `MLXLLM.ChatSession` grows the KV cache lazily up
        // to the model's trained 128K window. The catalog number only feeds
        // (a) the weak-model promotion in `ModelCapabilityProfile.isSmallVariant`
        // (≤2048 ⇒ weak — which is exactly what was wrongly demoting the 3B),
        // and (b) the history budget. `adjustContextLength` still clamps it to
        // the device tier (4096 on a moderate/free-account iPhone 16 Pro, 1024
        // on a tight SE), so raising the base only *unlocks* headroom on devices
        // that can use it — it can't push a small device past its tier ceiling.
        // ── Current generation (verified against the Hugging Face API, July 2026) ──
        //
        // Every `sizeBytes` and `requiresLargeMmapAddressing` below was read
        // from `https://huggingface.co/api/models/<repo>/tree/main`, not
        // estimated. All of these repos ship their weights as a **single**
        // `model.safetensors` (the accompanying `model.safetensors.index.json`
        // indexes that one file), so the largest shard equals the whole weight
        // file — which is what the sandboxed ~2.1 GB mmap ceiling applies to.
        //
        // `sizeBytes` is weights + tokenizer assets, i.e. what the user actually
        // downloads, so the storage pre-check and the progress bar agree with
        // reality.
        //
        // Re-verify these when bumping: a repo can be re-quantised or re-sharded
        // in place, and a stale `requiresLargeMmapAddressing: false` costs the
        // user a multi-GB download that ends in a refusal.

        // Qwen3 4B Instruct (2507 refresh) — the sweet spot on an entitled
        // 8 GB phone: markedly stronger instruction-following than the 2–3B
        // tier while still leaving room for a long conversation.
        LocalModel(
            id: "mlx-qwen3-4b-it-2507",
            displayName: "Qwen3 4B Instruct (MLX)",
            family: "Qwen3",
            parameterCount: "4B",
            quantization: "4-bit",
            sizeBytes: 2_279_000_000,           // HF: model.safetensors 2.263 GB + ~16 MB tokenizer
            contextLength: 4096,                // MLX grows KV lazily; adjustContextLength clamps per tier
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],     // 2.26 GB single shard > 2.1 GB ceiling → widened by effectiveRecommendedFor when entitled
            license: "Apache 2.0",
            backend: .mlx,
            format: .mlx,
            requiresLargeMmapAddressing: true
        ),

        // Qwen3 1.7B — modern replacement for the 1–2B slot. Fits the
        // sandboxed mmap ceiling comfortably, so it needs no entitlement.
        LocalModel(
            id: "mlx-qwen3-1.7b",
            displayName: "Qwen3 1.7B (MLX)",
            family: "Qwen3",
            parameterCount: "1.7B",
            quantization: "4-bit",
            sizeBytes: 984_000_000,             // HF: model.safetensors 968 MB + ~16 MB tokenizer
            contextLength: 4096,
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Apache 2.0",
            backend: .mlx,
            format: .mlx
        ),

        // Qwen3 8B — the largest text model worth attempting on an 8 GB phone,
        // and only with the entitlements: 4.6 GB of weights plus KV needs the
        // raised jetsam limit as well as the lifted mmap ceiling.
        LocalModel(
            id: "mlx-qwen3-8b",
            displayName: "Qwen3 8B (MLX)",
            family: "Qwen3",
            parameterCount: "8B",
            quantization: "4-bit",
            sizeBytes: 4_624_000_000,           // HF: model.safetensors 4.608 GB + ~16 MB tokenizer
            contextLength: 4096,
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Qwen3-8B-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],
            license: "Apache 2.0",
            backend: .mlx,
            format: .mlx,
            requiresLargeMmapAddressing: true
        ),

        // Gemma 3 1B (QAT) — quantisation-aware training, so it holds up far
        // better at 4-bit than a post-hoc quantised model this size. The
        // smallest entry that still gives usable Czech.
        LocalModel(
            id: "mlx-gemma-3-1b-it-qat",
            displayName: "Gemma 3 1B QAT (MLX)",
            family: "Gemma3",
            parameterCount: "1B",
            quantization: "4-bit (QAT)",
            sizeBytes: 772_000_000,             // HF: model.safetensors 733 MB + ~39 MB tokenizer
            contextLength: 4096,
            downloadURL: URL(static: "https://huggingface.co/mlx-community/gemma-3-1b-it-qat-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Gemma Terms of Use",
            backend: .mlx,
            format: .mlx
        ),

        // ── Gemma 3 4B QAT — WITHDRAWN, do not re-add without device testing ──
        //
        // This entry shipped briefly and **hard-crashed the app** on an
        // iPhone 16 Pro, reproducibly: five crashes in one session, each
        // immediately after `mlx.generate.start` for the post-load smoke test,
        // with ~3 GB of the 6 GB budget still free — so not a jetsam.
        //
        // Cause: `mlx-community/gemma-3-4b-it-qat-4bit` is **multimodal** — its
        // repo carries `preprocessor_config.json` and `processor_config.json`,
        // so MLX routes it to `VLMModelFactory`. But it was catalogued with
        // `family: "Gemma3"`, which resolves to the `.gemma` capability profile
        // and `supportsVision: false`. Generation therefore took the text-only
        // `ChatSession` path into a container whose processor expects the
        // image-token scaffolding, and the process died inside MLX.
        //
        // Marking it vision-capable would not have helped: the smoke test has
        // no images, so `shouldUseVisionInputPath(hasImages: false, …)` is
        // false and the text path is taken regardless. Making Gemma 3 VLM work
        // needs a real Gemma-3 vision profile plus a container-aware routing
        // decision — and that cannot be validated from a simulator, because
        // MLX inference needs Metal.
        //
        // The 1B QAT entry above is unaffected: its repo has no processor
        // configs, so it is a genuine text-only model.
        //
        // To restore: build the VLM routing, then verify on hardware that the
        // smoke test completes. Do not rely on "it compiles".

        // LFM2.5 1.2B — Liquid's edge-targeted architecture. Smallest entry
        // with genuinely usable instruction-following; useful on tight devices.
        // Falls to the `.default` capability profile (no dedicated family
        // entry), which is the conservative weak-model path — appropriate here.
        LocalModel(
            id: "mlx-lfm2.5-1.2b-it",
            displayName: "LFM2.5 1.2B (MLX)",
            family: "LFM",
            parameterCount: "1.2B",
            quantization: "4-bit",
            sizeBytes: 663_000_000,             // HF: model.safetensors 659 MB + ~5 MB tokenizer
            contextLength: 4096,
            downloadURL: URL(static: "https://huggingface.co/mlx-community/LFM2.5-1.2B-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "LFM Open License",
            backend: .mlx,
            format: .mlx
        ),

        LocalModel(
            id: "mlx-llama-3.2-3b-it",
            displayName: "Llama 3.2 3B (MLX)",
            family: "Llama",
            parameterCount: "3B",
            quantization: "4-bit",
            sizeBytes: 1_900_000_000,               // HF: 1.81 GB
            contextLength: 4096,
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Llama 3.2 Community License",
            backend: .mlx,
            format: .mlx
        ),

        // Llama 3.2 1B — fast, low-RAM fallback. Always treated as a weak
        // instruction follower (≤2B params) regardless of context, so it runs
        // the lean prompt path. Kept for tight devices and quick smoke tests.
        // contextLength raised to 4096 too (same MLX-lazy-KV rationale as the
        // 3B above) so multi-turn history isn't needlessly truncated; the weak
        // flag still fires off the parameter count, not the context.
        LocalModel(
            id: "mlx-llama-3.2-1b-it",
            displayName: "Llama 3.2 1B (MLX)",
            family: "Llama",
            parameterCount: "1B",
            quantization: "4-bit",
            sizeBytes: 750_000_000,                 // HF: 0.695 GB
            contextLength: 4096,
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Llama 3.2 Community License",
            backend: .mlx,
            format: .mlx
        ),

        // Phi 3.5 Mini — single `model.safetensors` shard of 2.15 GB
        // (verified against mlx-community/Phi-3.5-mini-instruct-4bit on
        // 2026-06). That single shard is just OVER the ~2.1 GB contiguous-
        // mmap ceiling enforced by the free-account per-shard pre-flight in
        // `MLXRuntime.loadWithProgress`, so on a non-entitled build it is
        // refused at load. Hence `recommendedFor: [.iPadMSeries]` only — do
        // NOT list it as an iPhone free-account recommendation, otherwise
        // the catalog pushes a 2.15 GB download that is then rejected. With
        // the extended-virtual-addressing entitlement (paid account) it
        // loads fine on an 8 GB iPhone; revisit the gating when entitlements
        // ship.
        LocalModel(
            id: "mlx-phi-3.5-mini-it",
            displayName: "Phi 3.5 Mini Instruct (MLX)",
            family: "Phi",
            parameterCount: "3.8B",
            quantization: "4-bit",
            sizeBytes: 2_150_000_000,               // HF: single model.safetensors = 2.15 GB (one shard, > 2.1 GB free ceiling)
            contextLength: 4096,                    // MLX grows KV lazily; adjustContextLength clamps to device tier
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Phi-3.5-mini-instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],         // 2.15 GB single shard > 2.1 GB free ceiling → needs entitlement
            license: "MIT",
            backend: .mlx,
            format: .mlx
        ),

        // Qwen 2.5 3B removed: swift-transformers 0.1.14 does not support
        // Qwen2Tokenizer — runtime throws unsupportedTokenizer on every load,
        // which deletes the cache and re-triggers the broken GGUF download
        // loop. Re-add once swift-transformers gains Qwen2Tokenizer support.

        LocalModel(
            id: "mlx-gemma-2-2b-it",
            displayName: "Gemma 2 2B Instruct (MLX)",
            family: "Gemma2",
            parameterCount: "2B",
            quantization: "4-bit",
            sizeBytes: 1_500_000_000,               // HF: 1.47 GB
            contextLength: 4096,                    // MLX grows KV lazily; adjustContextLength clamps to device tier
            downloadURL: URL(static: "https://huggingface.co/mlx-community/gemma-2-2b-it-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Gemma Terms of Use",
            backend: .mlx,
            format: .mlx
        ),

        // Gemma 3n E2B — MatFormer variant. The "2B active" routing slice
        // is a COMPUTE property, not a memory one: the full Per-Layer-
        // Embedding weights ship as a SINGLE `model.safetensors` shard of
        // ~4.46 GB (verified against mlx-community/gemma-3n-E2B-it-4bit on
        // 2026-06). A single 4.46 GB shard exceeds the ~2.1 GB contiguous-
        // mmap ceiling that stock iOS imposes WITHOUT the
        // extended-virtual-addressing entitlement, so the free-account
        // per-shard pre-flight in `MLXRuntime.loadWithProgress` refuses it
        // before any weight map-in. It therefore needs a paid Apple
        // Developer entitlement (and an 8 GB device) — same class as E4B,
        // hence `recommendedFor: [.iPadMSeries]` only. Do NOT mark this an
        // iPhone free-account recommendation: doing so makes the catalog
        // push a 4.5 GB download that is then rejected at load.
        LocalModel(
            id: "mlx-gemma-3n-e2b-it",
            displayName: "Gemma 3n E2B (MLX) - MatFormer",
            family: "Gemma3n",
            parameterCount: "5B (2B active)",
            quantization: "4-bit",
            sizeBytes: 4_460_000_000,           // HF: single model.safetensors = 4.46 GB (one shard)
            contextLength: 4096,                // MatFormer trained context; tier still clamps via adjustContextLength
            downloadURL: URL(static: "https://huggingface.co/mlx-community/gemma-3n-E2B-it-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],     // single 4.46 GB shard → needs extended-VA entitlement; not free-iPhone safe
            license: "Gemma Terms of Use",
            backend: .mlx,
            format: .mlx,
            requiresAuth: true
        ),

        // MARK: Ultra-small models (fast testing / low-RAM devices)

        LocalModel(
            id: "mlx-smollm2-360m-it",
            displayName: "SmolLM2 360M (MLX)",
            family: "SmolLM2",
            parameterCount: "360M",
            quantization: "4-bit",
            sizeBytes: 220_000_000,             // HF: ~210 MB
            contextLength: 1024,                // Ultra-low context for smallest model on memory-constrained devices
            downloadURL: URL(static: "https://huggingface.co/mlx-community/SmolLM2-360M-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Apache 2.0",
            backend: .mlx,
            format: .mlx
        ),

        LocalModel(
            id: "mlx-smollm2-1.7b-it",
            displayName: "SmolLM2 1.7B (MLX)",
            family: "SmolLM2",
            parameterCount: "1.7B",
            quantization: "4-bit",
            sizeBytes: 1_050_000_000,           // HF: ~1.0 GB
            contextLength: 2048,                // Optimized for iPhone KV cache stability
            downloadURL: URL(static: "https://huggingface.co/mlx-community/SmolLM2-1.7B-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Apache 2.0",
            backend: .mlx,
            format: .mlx
        ),

        // MARK: iPad M-series only (>3 GB — exceeds iPhone RAM)

        // Gemma 3n E4B — 4 B-active MatFormer slice, ~4.5 GB on disk as a
        // single safetensors shard. On stock iOS without the
        // `extended-virtual-addressing` entitlement (paid Apple Developer
        // Program + provisioning profile) the sandbox caps contiguous
        // mmap at ~2 GB, so this model jetsams during weight map-in even
        // when raw `os_proc_available_memory()` suggests it fits. iPad
        // M-series builds with entitlements run it cleanly. iPhone users
        // wanting MatFormer should reach for the E2B entry above. The
        // `recommendedFor: [.iPadMSeries]` here keeps the catalog from
        // pushing this entry into the iPhone recommendation slot.
        LocalModel(
            id: "mlx-gemma-3n-e4b-it",
            displayName: "Gemma 3n E4B (MLX) - MatFormer",
            family: "Gemma3n",
            parameterCount: "8B (4B active)",
            quantization: "4-bit",
            sizeBytes: 5_800_000_000,           // HF: 5.36 GB + 0.46 GB = ~5.8 GB; first shard alone is 5.36 GB
            contextLength: 4096,                // MatFormer architecture: 8B params but 4B active during inference
            // Bug-fix: previous URL pointed at `gemma-3-8b-it-4bit`
            // (regular Gemma 3, NOT 3n). Gemma 3n is the MatFormer
            // architecture variant; the user added it manually
            // because the catalog entry was wrong.
            downloadURL: URL(static: "https://huggingface.co/mlx-community/gemma-3n-E4B-it-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],
            license: "Gemma Terms of Use",
            backend: .mlx,
            format: .mlx,
            // Google's Gemma family is licence-gated even on mlx-community
            // mirrors — the user must accept terms on huggingface.co/google
            // and supply a token via Settings → Hugging Face before this
            // model can be fetched. Marked so the catalog UI can render the
            // "Vyžaduje přihlášení" badge and the downloader can fail fast
            // with a useful message when no token is stored.
            requiresAuth: true,
            // ~4.5 GB shipped as a single safetensors shard. Needs the
            // `extended-virtual-addressing` entitlement to mmap on iOS
            // — without it the runtime per-shard pre-flight refuses
            // before the load even starts.
            requiresLargeMmapAddressing: true
        ),

        LocalModel(
            id: "mlx-mistral-7b-v0.3",
            displayName: "Mistral 7B v0.3 (MLX)",
            family: "Mistral",
            parameterCount: "7B",
            quantization: "4-bit",
            sizeBytes: 4_100_000_000,           // HF: ~3.9 GB
            contextLength: 4096,                // Conservative for iPad safety (even large models)
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Mistral-7B-Instruct-v0.3-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],
            license: "Apache 2.0",
            backend: .mlx,
            format: .mlx,
            // A 3.9 GB 4-bit repo of this vintage ships its weights as one
            // `model.safetensors`, which cannot be mapped without
            // extended-virtual-addressing. The flag was set on the same-size
            // Gemma 3n E4B and Qwen2-VL entries but missed here, so a
            // non-entitled user got no warning and discovered the problem only
            // after downloading ~4 GB and hitting the runtime refusal.
            //
            // Erring towards `true` on an unverified shard layout is the safe
            // direction: a false positive costs one advisory line, a false
            // negative costs a 4 GB download. Confirm against the repo's
            // `model.safetensors.index.json` (absent ⇒ single shard) and clear
            // this if it turns out to be sharded.
            requiresLargeMmapAddressing: true
        ),

        LocalModel(
            id: "mlx-llama-3.1-8b-it",
            displayName: "Llama 3.1 8B (MLX)",
            family: "Llama",
            parameterCount: "8B",
            quantization: "4-bit",
            sizeBytes: 4_500_000_000,           // HF: ~4.3 GB
            contextLength: 4096,                // Conservative for iPad safety (even large models)
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],
            license: "Llama 3.1 Community License",
            backend: .mlx,
            format: .mlx,
            // Same reasoning as Mistral 7B above — 4.3 GB in what is very
            // likely a single shard, and the flag was missing while its
            // same-size-class siblings had it.
            requiresLargeMmapAddressing: true
        ),

        // MARK: Vision-Language Models (multimodal — image + text)
        //
        // These entries unlock the `supportsVision` profile path that
        // `PromptAssemblyService` checks before forwarding image bytes
        // to the runtime. Today the MLX runtime still uses
        // `LLMModelFactory` and ignores the image array — these models
        // therefore behave as text-only until the
        // `VLMModelFactory` swap lands. Catalog entries are kept here
        // ahead of that swap so the download flow is ready and the
        // UI can render the "Vision" badge.
        //
        // Picked these three as the sweet spot:
        //   - SmolVLM 256M is the smallest practical vision model that
        //     still reads images (≈200 MB) — great for iPhone 16 Pro.
        //   - SmolVLM 500M trades RAM for better recognition quality.
        //   - Qwen2-VL 2B is the highest quality that comfortably fits
        //     an iPhone 16 Pro; the 7B variant is iPad-only.

        LocalModel(
            id: "mlx-smolvlm-256m-it",
            displayName: "SmolVLM 256M (MLX, Vision)",
            family: "SmolVLM",
            parameterCount: "256M",
            quantization: "4-bit",
            sizeBytes: 220_000_000,             // HF: ~200 MB
            contextLength: 2048,                // Vision tokens budget eats into context; keep modest
            downloadURL: URL(static: "https://huggingface.co/mlx-community/SmolVLM-256M-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Apache 2.0",
            backend: .mlx,
            format: .mlx
        ),

        LocalModel(
            id: "mlx-smolvlm-500m-it",
            displayName: "SmolVLM 500M (MLX, Vision)",
            family: "SmolVLM",
            parameterCount: "500M",
            quantization: "4-bit",
            sizeBytes: 420_000_000,             // HF: ~400 MB
            contextLength: 2048,
            downloadURL: URL(static: "https://huggingface.co/mlx-community/SmolVLM-500M-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Apache 2.0",
            backend: .mlx,
            format: .mlx
        ),

        LocalModel(
            // Qwen3-VL 2B — current-generation vision model and the smaller of
            // the two most-downloaded VLMs on mlx-community. Fits the sandboxed
            // mmap ceiling, so it works without the entitlements.
            //
            // The family string matters: `ModelCapabilityProfile.baseProfile`
            // used to detect Qwen VLMs with an exact "qwen-vl" / "qwen2-vl"
            // list, so "Qwen3-VL" resolved to the *text-only* profile and
            // `shouldUseVisionInputPath` silently dropped attached images.
            // That detection is now `contains("qwen") && contains("vl")`.
            id: "mlx-qwen3-vl-2b-it",
            displayName: "Qwen3-VL 2B (MLX, vision)",
            family: "Qwen3-VL",
            parameterCount: "2B",
            quantization: "4-bit",
            sizeBytes: 1_798_000_000,           // HF: model.safetensors 1.782 GB + ~16 MB tokenizer
            contextLength: 2048,                // Vision tokens eat into context; keep modest
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Qwen3-VL-2B-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Apache 2.0",
            backend: .mlx,
            format: .mlx
        ),

        // Qwen3-VL 4B — the most-downloaded VLM on mlx-community. Stronger
        // grounding than the 2B at the cost of needing the entitlements.
        LocalModel(
            id: "mlx-qwen3-vl-4b-it",
            displayName: "Qwen3-VL 4B (MLX, vision)",
            family: "Qwen3-VL",
            parameterCount: "4B",
            quantization: "4-bit",
            sizeBytes: 3_110_000_000,           // HF: model.safetensors 3.094 GB + ~16 MB tokenizer
            contextLength: 4096,
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],
            license: "Apache 2.0",
            backend: .mlx,
            format: .mlx,
            requiresLargeMmapAddressing: true
        ),

        LocalModel(
            id: "mlx-qwen2-vl-2b-it",
            displayName: "Qwen2-VL 2B (MLX, Vision)",
            family: "Qwen2-VL",
            parameterCount: "2B",
            quantization: "4-bit",
            sizeBytes: 1_650_000_000,           // HF: ~1.55 GB
            contextLength: 2048,
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Qwen2-VL-2B-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "Qwen RESEARCH LICENSE",
            backend: .mlx,
            format: .mlx
        ),

        // 7B variant — iPad M-series only. Same architecture as 2B
        // but the safetensors shard pushes ~4.5 GB and inference
        // memory pressure is meaningfully higher; iPhone 16 Pro
        // would jetsam during prefill on long image inputs.
        LocalModel(
            id: "mlx-qwen2-vl-7b-it",
            displayName: "Qwen2-VL 7B (MLX, Vision)",
            family: "Qwen2-VL",
            parameterCount: "7B",
            quantization: "4-bit",
            sizeBytes: 4_500_000_000,           // HF: ~4.3 GB
            contextLength: 4096,
            downloadURL: URL(static: "https://huggingface.co/mlx-community/Qwen2-VL-7B-Instruct-4bit"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPadMSeries],
            license: "Qwen RESEARCH LICENSE",
            backend: .mlx,
            format: .mlx,
            // Same mmap entitlement story as Gemma 3n E4B — single
            // shard >2 GB so iOS sandbox needs the extended VA
            // entitlement before the runtime can map weights.
            requiresLargeMmapAddressing: true
        ),

        // MARK: Image generation (Core ML Stable Diffusion)
        //
        // These entries drive the `/image PROMPT` slash command in
        // chat. `CoreMLStableDiffusionRuntime` resolves the modelID
        // to a directory under
        // `Application Support/Models/coreml-sd/<id>/` and hands that
        // path to `StableDiffusionPipeline(resourcesAt:)`.
        //
        // v1 ships SD 2.1 base palettized only:
        //   - Best size/quality trade-off for an 8 GB iPhone (~1.6 GB
        //     on disk, ~1.5 GB resident at runtime, ~2-3 GB peak with
        //     reduceMemory: true).
        //   - 4-bit palettized weights tuned for CPU+NE execution via
        //     Apple's split_einsum_v2 conversion.
        //   - 512×512 native output; chat surface renders it inline.
        //
        // Larger variants (SDXL, FLUX) are intentionally NOT in v1 —
        // they don't fit iPhone RAM and their pipeline shapes differ
        // enough that the runtime needs separate code paths.
        LocalModel(
            id: "coreml-sd-2-1-base-palettized",
            displayName: "Stable Diffusion 2.1 Base (Core ML, palettized)",
            family: "Stable Diffusion 2.1",
            parameterCount: "865M",             // U-Net params; matches HF card
            quantization: "4-bit palettized",
            sizeBytes: 1_650_000_000,           // HF: ~1.55 GB across .mlmodelc bundles
            contextLength: 77,                  // CLIP token cap — display-only for this format
            downloadURL: URL(static: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized"),
            sha256: nil,
            installState: .notInstalled,
            // Marked iPhone-compatible based on Apple's published
            // benchmarks (iPhone 14+ run the palettized variant
            // ~20-40 s per 20-step turn). iPhone 16 Pro Neural
            // Engine compresses that further. Verify on real device
            // before shipping — the simulator path downgrades to
            // .cpuOnly automatically and is much slower.
            recommendedFor: [.iPhone, .iPadMSeries],
            license: "CreativeML Open RAIL-M (model) + MIT (pipeline)",
            backend: .coreML,
            format: .coreMLPackage,
            // No single .mlmodelc weight file exceeds the 2 GB mmap
            // ceiling — the palettized U-Net's largest shard is
            // ~700 MB. So no extended-VA entitlement needed unlike
            // Gemma 3n E4B or Qwen2-VL 7B.
            requiresLargeMmapAddressing: false
        ),
    ]
}
