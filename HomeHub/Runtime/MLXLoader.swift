import Foundation
import MLXLMCommon

/// Narrow protocol for the model container, allowing mocks in tests.
protocol MLXModelContainer: Sendable {
    func perform<R: Sendable>(
        _ action: @Sendable (ModelContext) async throws -> sending R
    ) async rethrows -> sending R
}

extension ModelContainer: MLXModelContainer {}

/// Narrow protocol for loading an MLX model container.
///
/// This exists as a test seam to allow deterministic mocking of the
/// download/init flow in unit and UI tests without requiring real
/// multi-GB Hub downloads.
protocol MLXLoader: Sendable {
    func load(
        configuration: ModelConfiguration,
        downloader: any Downloader,
        tokenizerLoader: any TokenizerLoader,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> any MLXModelContainer
}

/// Production implementation that delegates to the real `MLXLMCommon.loadModelContainer`.
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
