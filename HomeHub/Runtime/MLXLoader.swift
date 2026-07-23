import Foundation
import MLXLMCommon

/// Narrow protocol for the model container, allowing mocks in tests.
protocol MLXModelContainer: Sendable {
    /// Run `action` against the model's context.
    ///
    /// Declared `throws`, not `rethrows`. `rethrows` would restrict a conformer
    /// to failing only when `action` itself fails, which is fine for the real
    /// `ModelContainer` but leaves a stub with **no way to say "I cannot run
    /// inference"** — it can only trap. That is exactly what the test fake did,
    /// and a trap during normal test execution kills the runner and takes every
    /// other result in the run with it.
    ///
    /// A `rethrows` function satisfies a `throws` requirement, so
    /// `extension ModelContainer: MLXModelContainer {}` below still conforms
    /// unchanged and real call sites keep their existing behaviour.
    func perform<R: Sendable>(
        _ action: @Sendable (ModelContext) async throws -> sending R
    ) async throws -> sending R
}

extension ModelContainer: MLXModelContainer {}

/// Test seam for the MLX model loader.
///
/// In production this delegates to `MLXLMCommon.loadModelContainer(...)` —
/// the canonical mlx-swift-lm entry point. The shape of this protocol
/// mirrors that function so swapping it for `LLMModelFactory.shared.loadContainer`
/// in the future stays a one-line change without touching `MLXRuntime`.
///
/// The `Downloader` and `TokenizerLoader` parameters are deliberately
/// surfaced rather than hidden inside the loader so production wiring
/// (`HubApiDownloader` + `SwiftTransformersTokenizerLoader` from
/// `HubIntegration.swift`) and test wiring (in-memory stubs) share the
/// same call shape.
protocol MLXLoader: Sendable {
    func load(
        configuration: ModelConfiguration,
        downloader: any Downloader,
        tokenizerLoader: any TokenizerLoader,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> any MLXModelContainer
}

/// Production implementation. Forwards directly to
/// `MLXLMCommon.loadModelContainer(from:using:configuration:progressHandler:)`,
/// the canonical mlx-swift-lm loading entry point.
///
/// `LLMModelFactory.shared.loadContainer(...)` (newer high-level wrapper)
/// is API-compatible if we ever want to skip the explicit `Downloader` /
/// `TokenizerLoader` wiring; the protocol shape above keeps that swap
/// localised to this file.
struct DefaultMLXLoader: MLXLoader {
    func load(
        configuration: ModelConfiguration,
        downloader: any Downloader,
        tokenizerLoader: any TokenizerLoader,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> any MLXModelContainer {
        try await loadModelContainer(
            from: downloader,
            using: tokenizerLoader,
            configuration: configuration,
            progressHandler: progressHandler
        )
    }
}
