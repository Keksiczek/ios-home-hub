import Foundation
import MLXLMCommon

/// A deterministic fake loader for MLX models, used in unit and UI tests.
///
/// It simulates the two-phase load (download -> prepare) without any
/// network or heavy compute.
final class FakeMLXLoader: MLXLoader, @unchecked Sendable {
    
    enum Behavior: Sendable, Equatable {
        case success
        case failure(String)
        case slowProgress(steps: Int, delay: TimeInterval)
        case instant
        
        static func == (lhs: Behavior, rhs: Behavior) -> Bool {
            switch (lhs, rhs) {
            case (.success, .success): return true
            case (.instant, .instant): return true
            case (.failure(let l), .failure(let r)): return l == r
            case (.slowProgress(let ls, let ld), .slowProgress(let rs, let rd)):
                return ls == rs && ld == rd
            default: return false
            }
        }
    }
    
    var behavior: Behavior = .success
    
    func load(
        configuration: ModelConfiguration,
        downloader: any Downloader,
        tokenizerLoader: any TokenizerLoader,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> any MLXModelContainer {
        
        switch behavior {
        case .success, .instant:
            let progress = Progress(totalUnitCount: 100)
            progress.completedUnitCount = 100
            progressHandler(progress)
            return MockMLXModelContainer()
            
        case .failure(let reason):
            throw RuntimeError.initializationFailed(reason)
            
        case .slowProgress(let steps, let delay):
            let progress = Progress(totalUnitCount: Int64(steps))
            for i in 0...steps {
                if Task.isCancelled {
                    // Simulate a small delay during cancellation to ensure
                    // the UI has time to show the cancelling state if needed.
                    throw CancellationError()
                }
                progress.completedUnitCount = Int64(i)
                progressHandler(progress)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            return MockMLXModelContainer()
        }
    }
}

/// A mock MLX container that satisfies the protocol shape but cannot
/// run inference. It exists so progress / lifecycle tests can drive the
/// load → unload state machine without spinning up Metal.
///
/// `perform(_:)` traps on purpose: the only way to reach it is via
/// `MLXRuntime.generate(...)` against a fake-loaded model, which is a
/// programming error in the test setup — production code never wires
/// `FakeMLXLoader` outside the `--use-fake-mlx-loader` argument path.
/// The trap message is chosen to make that obvious in the failure log.
final class MockMLXModelContainer: MLXModelContainer, @unchecked Sendable {
    func perform<R: Sendable>(
        _ action: @Sendable (ModelContext) async throws -> sending R
    ) async rethrows -> sending R {
        fatalError(
            "MockMLXModelContainer.perform was invoked. This container is for " +
            "load/unload lifecycle tests only — driving `MLXRuntime.generate` " +
            "against it indicates the test wired the fake loader into a code " +
            "path that requires a real Metal-backed container."
        )
    }
}
