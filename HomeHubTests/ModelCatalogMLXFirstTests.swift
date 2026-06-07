import XCTest
@testable import HomeHub

/// Pins the MLX-first product invariants in the curated catalog and the
/// derived selectors. These are the affordances onboarding and "first
/// open" rely on; if any of them silently regress to a `.llamaCpp`
/// model, fresh MLX-only builds drop the user into a load failure.
@MainActor
final class ModelCatalogMLXFirstTests: XCTestCase {

    private let catalog = ModelCatalogService()

    // MARK: - Catalog shape

    func testCatalogContainsAtLeastOneMLXModel() {
        let mlxModels = catalog.models.filter { $0.backend == .mlx }
        XCTAssertFalse(
            mlxModels.isEmpty,
            "Curated catalog must ship at least one MLX entry — MLX is the " +
            "primary runtime and the catalog is the only place onboarding " +
            "looks for a default."
        )
    }

    func testCatalogShipsAtLeastOneIPhoneSafeMLXModel() {
        let candidates = catalog.models.filter {
            $0.backend == .mlx && $0.recommendedFor.contains(.iPhone)
        }
        XCTAssertFalse(
            candidates.isEmpty,
            "At least one curated MLX entry must be marked iPhone-safe so " +
            "iPhone users have a working default after onboarding."
        )
    }

    func testEveryGGUFEntryIsExplicitAboutBackendAndFormat() {
        // Catch the pitfall where a contributor adds a new GGUF entry and
        // relies on the init defaults (which now point at MLX). A GGUF entry
        // not marked explicitly would silently route to MLXRuntime and fail.
        let suspect = catalog.models.filter {
            $0.downloadURL.absoluteString.hasSuffix(".gguf")
                && ($0.backend != .llamaCpp || $0.format != .gguf)
        }
        XCTAssertTrue(
            suspect.isEmpty,
            "Every catalog entry whose downloadURL ends in `.gguf` must set " +
            "backend: .llamaCpp and format: .gguf explicitly. Offending IDs: " +
            suspect.map(\.id).joined(separator: ", ")
        )
    }

    // MARK: - Onboarding-critical selectors

    func testRecommendedStarterIsAlwaysMLX() {
        XCTAssertEqual(
            catalog.recommendedStarter.backend,
            .mlx,
            "recommendedStarter must be an MLX entry — onboarding sets it as " +
            "the default selection on the picker. A GGUF starter only loads " +
            "with HOMEHUB_LLAMA_RUNTIME=1, which fresh checkouts don't have."
        )
    }

    func testIPhoneSmokeTestModelIsMLXOnDefaultBuild() {
        let model = catalog.iPhoneSmokeTestModel
        // MLX is always available; the smoke-test model should prefer MLX
        // so the developer-diagnostics smoke flow works without opt-in.
        XCTAssertEqual(
            model.backend,
            .mlx,
            "iPhoneSmokeTestModel should be MLX so the dev-diagnostics smoke " +
            "test runs on the default build. Got: \(model.id) (\(model.backend.rawValue))"
        )
    }

    // MARK: - Build-time availability

    func testMLXIsAlwaysAvailable() {
        XCTAssertTrue(
            RuntimeBackendAvailability.mlxAvailable,
            "MLX is the primary runtime — it must always be linked."
        )
    }

    func testRecommendedStarterIsUsableInThisBuild() {
        XCTAssertTrue(
            catalog.recommendedStarter.isUsableInThisBuild,
            "recommendedStarter must be loadable by the current build, not " +
            "just present in the catalog. Currently: " +
            "\(catalog.recommendedStarter.id) (\(catalog.recommendedStarter.backend.rawValue))"
        )
    }

    func testGGUFEntriesReportUnavailableOnDefaultBuild() {
        // On the default MLX-only build, GGUF entries must surface a non-nil
        // unavailableReason so the UI can render a clear "needs opt-in" state.
        // On HOMEHUB_LLAMA_RUNTIME builds GGUF is fine and the assertion is
        // intentionally inverted.
        let gguf = catalog.models.filter { $0.backend == .llamaCpp }
        guard !gguf.isEmpty else { return }
        if RuntimeBackendAvailability.llamaCppAvailable {
            for m in gguf {
                XCTAssertNil(m.unavailableReason, "GGUF model \(m.id) should be usable when llama.cpp is linked")
                XCTAssertTrue(m.isUsableInThisBuild)
            }
        } else {
            for m in gguf {
                XCTAssertNotNil(m.unavailableReason, "GGUF model \(m.id) must surface an opt-in hint on MLX-only builds")
                XCTAssertFalse(m.isUsableInThisBuild)
            }
        }
    }

    // MARK: - Error copy

    func testBackendUnavailableErrorIsActionable() {
        // The exact wording is product copy and may evolve, but it must
        // remain actionable: tell the user the model name AND mention the
        // opt-in flag / xcframework so they know what to do next.
        let err = RuntimeError.backendUnavailable(
            modelName: "Test Model",
            backend: .llamaCpp
        )
        let description = err.errorDescription ?? ""
        XCTAssertTrue(description.contains("Test Model"))
        XCTAssertTrue(description.contains("HOMEHUB_LLAMA_RUNTIME"))
        XCTAssertTrue(description.contains("llama.xcframework"))
    }

    // MARK: - usableModels / unusableModels accessors

    func testUsableModelsContainsEveryMLXEntry() {
        let mlx = catalog.models.filter { $0.backend == .mlx }
        for m in mlx {
            XCTAssertTrue(
                catalog.usableModels.contains(where: { $0.id == m.id }),
                "MLX model \(m.id) must appear in usableModels — MLX is always linked."
            )
        }
    }

    func testUsableAndUnusableArePartitioned() {
        let usable = Set(catalog.usableModels.map(\.id))
        let unusable = Set(catalog.unusableModels.map(\.id))
        XCTAssertTrue(usable.isDisjoint(with: unusable),
                      "A model cannot be both usable and unusable simultaneously")
        XCTAssertEqual(
            usable.union(unusable).count,
            catalog.models.count,
            "usableModels ∪ unusableModels must cover the entire catalog"
        )
    }

    func testUsableModelsIsNeverEmpty() {
        XCTAssertFalse(
            catalog.usableModels.isEmpty,
            "Default build must have at least one usable model — otherwise " +
            "first-run onboarding lands the user in an empty picker."
        )
    }

    // MARK: - recommendedStarter defensive fallback ladder

    func testRecommendedStarterIsAlwaysUsable() {
        // The fallback ladder must never leak a model the build can't load.
        XCTAssertTrue(catalog.recommendedStarter.isUsableInThisBuild)
    }

    func testRecommendedStarterPrefersIPhoneSafeMLX() {
        // The first tier of the priority ladder must always win when the
        // catalog has at least one iPhone-safe MLX entry (which the
        // validator enforces).
        let starter = catalog.recommendedStarter
        XCTAssertEqual(starter.backend, .mlx)
        XCTAssertTrue(
            starter.recommendedFor.contains(.iPhone),
            "recommendedStarter should prefer iPhone-safe entries when " +
            "available — got \(starter.id) which is iPad-only."
        )
    }

    // MARK: - Answer-quality regression guards (free-account lean-mode fixes)
    //
    // These lock in the three fixes that stop capable small models from
    // collapsing into the lean (weak-instruction-follower) prompt path on a
    // free Apple Developer account, which is what made answers feel degraded
    // versus minimal chat apps.

    /// Fix 1: the persona must stay network-neutral. The old wording ("no
    /// internet access / no external services") contradicted the default-on
    /// WebSearch tool and made small models refuse to search.
    func testDefaultPersonaIsNetworkNeutral() {
        let prompt = AssistantProfile.defaultSystemPrompt.lowercased()
        XCTAssertFalse(
            prompt.contains("no internet"),
            "Persona must not hard-code a 'no internet' claim — it contradicts " +
            "the default-on WebSearch tool. Network capability is owned by the " +
            "dynamic tool/privacy rails in PromptAssemblyService."
        )
        XCTAssertFalse(
            prompt.contains("external services"),
            "Persona must not claim it calls no external services while " +
            "WebSearch / FetchPage are enabled by default."
        )
        XCTAssertEqual(
            AssistantProfile.defaultAssistant.systemPromptBase,
            AssistantProfile.defaultSystemPrompt,
            "Shipped default assistant should use the network-neutral persona."
        )
    }

    /// Fix 2: onboarding's default model must be a STRONG instruction follower
    /// so the default chat keeps the full (non-lean) prompt stack.
    func testRecommendedStarterIsStrongInstructionFollower() {
        let starter = catalog.recommendedStarter
        let profile = ModelCapabilityProfile.resolve(
            family: starter.family,
            parameterCount: starter.parameterCount,
            contextLength: starter.contextLength
        )
        XCTAssertFalse(
            profile.isWeakInstructionFollower,
            "recommendedStarter (\(starter.id)) must resolve to a STRONG " +
            "instruction follower so onboarding defaults to the full prompt " +
            "stack — a weak default forces lean mode and degrades answers."
        )
    }

    /// Fix 3: the capable 3B chat model must declare context > 2048 so the
    /// `isSmallVariant` (≤2048 ⇒ weak) rule doesn't demote it on the MLX path
    /// (where the catalog value doesn't set a hard n_ctx anyway).
    func testLlama3BAvoidsContextWeakPromotion() {
        guard let model = catalog.models.first(where: { $0.id == "mlx-llama-3.2-3b-it" }) else {
            return XCTFail("Llama 3.2 3B entry missing from the curated catalog.")
        }
        XCTAssertGreaterThan(model.contextLength, 2048,
            "Llama 3.2 3B must declare context > 2048 to avoid the weak demotion.")
        let profile = ModelCapabilityProfile.resolve(
            family: model.family,
            parameterCount: model.parameterCount,
            contextLength: model.contextLength
        )
        XCTAssertFalse(profile.isWeakInstructionFollower,
            "Llama 3.2 3B should resolve strong with its catalog context.")
    }

    /// Guard-rail: the context bump must NOT have turned every model strong.
    /// The 1B is weak by parameter count (≤2B) regardless of context.
    func testLlama1BStaysWeakByParameterCount() {
        guard let model = catalog.models.first(where: { $0.id == "mlx-llama-3.2-1b-it" }) else {
            return XCTFail("Llama 3.2 1B entry missing from the curated catalog.")
        }
        let profile = ModelCapabilityProfile.resolve(
            family: model.family,
            parameterCount: model.parameterCount,
            contextLength: model.contextLength
        )
        XCTAssertTrue(profile.isWeakInstructionFollower,
            "Llama 3.2 1B is ≤2B and must stay on the lean path even with a " +
            "raised context.")
    }

    // MARK: - Free-account memory safety (regression guard)

    /// Every MLX model the catalog recommends for iPhone must fit the
    /// free-account single-shard mmap ceiling on a non-entitled build.
    ///
    /// Otherwise the catalog advertises a multi-GB download that the runtime's
    /// per-shard pre-flight (`MLXRuntime.loadWithProgress`) then refuses — the
    /// exact "download-then-fail" trap that previously mis-tagged Gemma 3n E2B
    /// (single 4.46 GB shard) and Phi-3.5 Mini (single 2.15 GB shard) as
    /// iPhone-safe.
    ///
    /// `sizeBytes` is the total weight size; every iPhone-class MLX 4-bit model
    /// in the curated catalog ships its weights as ONE `model.safetensors`
    /// shard, so total == largest shard and the comparison is exact. A future
    /// multi-shard entry with small shards but a large total would trip this
    /// conservatively — acceptable; the fix at that point is to compare real
    /// per-shard sizes.
    func testIPhoneRecommendedMLXModelsFitFreeAccountCeiling() throws {
        // Only meaningful WITHOUT the extended-virtual-addressing entitlement.
        // With it, contiguous mmaps are bounded only by RAM and large iPhone
        // models are legitimate.
        try XCTSkipIf(
            DeviceMemoryProvider.kernelEntitlementsEnabled,
            "Entitled build — the free-account single-shard ceiling does not apply."
        )

        let ceiling = DeviceMemoryProvider.sandboxedSingleShardCeilingBytes
        let offenders = catalog.models.filter {
            $0.backend == .mlx
                && $0.recommendedFor.contains(.iPhone)
                && $0.sizeBytes > ceiling
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "These MLX models are recommended for iPhone but their weights exceed " +
            "the \(ceiling / 1_000_000) MB free-account single-shard ceiling, so the " +
            "runtime pre-flight refuses them after a multi-GB download: " +
            offenders.map { "\($0.id) (\($0.sizeBytes / 1_000_000) MB)" }
                .joined(separator: ", ") +
            ". Re-tag them recommendedFor: [.iPadMSeries] (needs entitlement)."
        )
    }
}
