import Foundation
import MLXLMCommon

/// Narrow protocol for the model container, allowing mocks in tests.
protocol MLXModelContainer: Sendable {
    func perform<R: Sendable>(
        _ action: @Sendable (ModelContext) async throws -> sending R
    ) async rethrows -> sending R
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
