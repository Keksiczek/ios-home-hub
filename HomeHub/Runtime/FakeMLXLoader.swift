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

    /// How the container this loader returns should behave when
    /// `MLXRuntime.generate` reaches it. Defaults to failing immediately;
    /// set `.blockUntilCancelled` for tests that need a generation to still be
    /// in flight when they call `unload()`.
    var containerBehaviour: MockMLXModelContainer.Behaviour = .failImmediately

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
            return MockMLXModelContainer(behaviour: containerBehaviour)
            
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
            return MockMLXModelContainer(behaviour: containerBehaviour)
        }
    }
}

/// Failure surfaced by `MockMLXModelContainer.perform`.
enum MockContainerError: Error, CustomStringConvertible {
    /// The container cannot run inference — it has no Metal device and no
    /// real `ModelContext` to hand to the caller's closure.
    case inferenceUnsupported

    var description: String {
        "MockMLXModelContainer cannot run inference: it has no Metal-backed "
        + "ModelContext. Lifecycle and error-path tests are supported; token "
        + "generation is not."
    }
}

/// A mock MLX container that satisfies the protocol shape but cannot run
/// inference. It exists so progress / lifecycle tests can drive the
/// load → unload state machine without spinning up Metal.
///
/// ## Why `perform` throws instead of trapping
///
/// It used to `fatalError`, on the reasoning that reaching it could only be a
/// test-setup mistake. That reasoning was wrong in one important case:
/// **cancellation and unload-during-generation are lifecycle concerns, and
/// testing them requires `generate()` to actually start.** So the trap fired on
/// legitimate tests.
///
/// The cost was worse than a failed assertion. A `fatalError` kills the test
/// runner, so all four `MLXHardeningTests` were lost to a process restart
/// rather than reported — six restarts in a full run — and every other result
/// in the run became less trustworthy. A trap that fires during normal test
/// execution is a liability, not a safety net.
///
/// Throwing keeps the intent (the fake cannot generate tokens, and pretending
/// otherwise would test nothing) while letting `MLXRuntime`'s error epilogue run
/// — which is itself worth covering, since it must clear `isGenerating`,
/// `activeSession` and `activeTask` even when generation fails.
final class MockMLXModelContainer: MLXModelContainer, @unchecked Sendable {
    /// How `perform` should behave. Lets a single fake serve both the
    /// "generation fails cleanly" and "generation is in flight long enough to
    /// be cancelled" scenarios without a second mock type.
    enum Behaviour: Sendable {
        /// Throw `MockContainerError.inferenceUnsupported` immediately.
        case failImmediately
        /// Suspend until the surrounding task is cancelled, then throw
        /// `CancellationError`. Makes "unload during an in-flight generation"
        /// deterministic instead of a race against how fast the fake returns.
        case blockUntilCancelled
    }

    let behaviour: Behaviour

    init(behaviour: Behaviour = .failImmediately) {
        self.behaviour = behaviour
    }

    func perform<R: Sendable>(
        _ action: @Sendable (ModelContext) async throws -> sending R
    ) async throws -> sending R {
        // `action` is never invoked: there is no way to construct a valid
        // `ModelContext` without a real model, tokenizer and Metal device,
        // which is the whole reason this fake exists. Reporting that as a
        // thrown error rather than a trap is what lets `MLXRuntime`'s failure
        // epilogue run and be asserted on.
        if case .blockUntilCancelled = behaviour {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            throw CancellationError()
        }
        throw MockContainerError.inferenceUnsupported
    }
}
