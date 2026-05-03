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
}
