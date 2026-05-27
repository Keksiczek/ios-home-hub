import XCTest
@testable import HomeHub

/// Tests for `StubImageGenerationRuntime`.
///
/// The stub serves two production-relevant roles even after the real
/// `CoreMLStableDiffusionRuntime` ships:
///   1. **Test substitute** — unit tests inject it so they don't have to
///      download multi-GB diffusion weights to exercise the chat pipeline.
///   2. **Fallback** — if a user device fails to load Core ML weights
///      (out-of-memory, missing files, simulator without Neural Engine),
///      `AppContainer` can keep the stub wired up so `/image` still
///      *something* visibly distinct rather than silently failing.
///
/// Both roles depend on the stub being **deterministic** (same prompt →
/// same PNG bytes) and **promptly cancellable** (explicit `cancel()`
/// short-circuits before the next progress tick).
final class StubImageGenerationRuntimeTests: XCTestCase {

    // MARK: - Determinism

    func testSamePromptProducesIdenticalImage() async throws {
        let runtime = StubImageGenerationRuntime()
        try await runtime.load(modelID: "stub-test")

        let first  = try await renderToPNG(runtime, prompt: "a moonlit fox")
        let second = try await renderToPNG(runtime, prompt: "a moonlit fox")

        // The gradient is derived from the prompt's FNV-1a hash, so
        // identical prompts MUST produce identical bytes. If a future
        // refactor swaps the hash algorithm or changes the renderer's
        // output (different scale, opacity, font), this fails and
        // forces a deliberate decision rather than a silent break of
        // any snapshot-style downstream tests.
        XCTAssertEqual(first, second, "Stub must be deterministic across calls for the same prompt")
    }

    func testDifferentPromptsProduceDifferentImages() async throws {
        let runtime = StubImageGenerationRuntime()
        try await runtime.load(modelID: "stub-test")

        let cat = try await renderToPNG(runtime, prompt: "cat")
        let dog = try await renderToPNG(runtime, prompt: "dog")

        // FNV-1a hash collisions for two 3-letter inputs are
        // astronomically unlikely; this asserts the stub is actually
        // using the prompt in its colour derivation rather than
        // returning a constant payload.
        XCTAssertNotEqual(cat, dog, "Different prompts must yield different gradient colours")
    }

    // MARK: - Lifecycle

    func testLoadedModelIDReflectsLastLoad() async throws {
        let runtime = StubImageGenerationRuntime()
        let before = await runtime.loadedModelID
        XCTAssertNil(before)

        try await runtime.load(modelID: "stub-test")
        let afterLoad = await runtime.loadedModelID
        XCTAssertEqual(afterLoad, "stub-test")

        await runtime.unload()
        let afterUnload = await runtime.loadedModelID
        XCTAssertNil(afterUnload)
    }

    // MARK: - Cancellation

    func testExplicitCancelStopsGeneration() async throws {
        let runtime = StubImageGenerationRuntime()
        try await runtime.load(modelID: "stub-test")

        // Long-step prompt so the cancel has a window to land before
        // the gradient render. The stub yields up to 4 progress ticks
        // 40 ms apart — we cancel after the first tick and assert the
        // stream surfaces `.cancelled` rather than `.finished`.
        let stream = runtime.generate(parameters: ImageGenerationParameters(
            prompt: "long generation",
            steps: 20
        ))

        var didCancel = false
        var sawFinished = false
        var cancelError: ImageGenerationError?

        do {
            for try await event in stream {
                switch event {
                case .progress:
                    if !didCancel {
                        didCancel = true
                        await runtime.cancel()
                    }
                case .preview:
                    continue
                case .finished:
                    sawFinished = true
                case .failed(let err):
                    cancelError = err as? ImageGenerationError
                }
            }
        } catch let err as ImageGenerationError {
            cancelError = err
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertFalse(sawFinished, "Cancelled stream must not emit .finished")
        XCTAssertEqual(cancelError, .cancelled, "Cancel must surface as ImageGenerationError.cancelled")
    }

    func testCancelFlagResetsBetweenRuns() async throws {
        // Regression guard: if `cancel()` set the flag but `generate(...)`
        // didn't reset it on entry, a single user-cancelled run would
        // poison every subsequent generation in the same app session.
        let runtime = StubImageGenerationRuntime()
        try await runtime.load(modelID: "stub-test")

        // Run 1: cancel mid-flight.
        let stream1 = runtime.generate(parameters: ImageGenerationParameters(prompt: "first", steps: 20))
        var didCancel = false
        do {
            for try await event in stream1 {
                if case .progress = event, !didCancel {
                    didCancel = true
                    await runtime.cancel()
                }
            }
        } catch { /* expected cancellation */ }

        // Run 2: must complete normally (the .cancelled flag from
        // run 1 should be reset on entry, not still tripping the
        // early-exit branch).
        let png = try await renderToPNG(runtime, prompt: "second")
        XCTAssertGreaterThan(png.count, 100, "Second run must produce a real PNG, not be poisoned by run 1's cancel flag")
    }

    // MARK: - Helpers

    /// Collect a single generation to PNG bytes. Fails the test if the
    /// stream ends without yielding `.finished`.
    private func renderToPNG(
        _ runtime: StubImageGenerationRuntime,
        prompt: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Data {
        let stream = runtime.generate(parameters: ImageGenerationParameters(prompt: prompt))
        var data: Data?
        for try await event in stream {
            if case .finished(let image) = event { data = image.data }
        }
        let bytes = try XCTUnwrap(data, "Stream must yield .finished for prompt \"\(prompt)\"", file: file, line: line)
        return bytes
    }
}
