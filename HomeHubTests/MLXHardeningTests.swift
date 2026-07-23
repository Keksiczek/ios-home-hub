import XCTest
@testable import HomeHub
import MLXLMCommon

/// Lifecycle hardening for `MLXRuntime`, driven by `FakeMLXLoader`.
///
/// ## What this fake can and cannot exercise
///
/// `MockMLXModelContainer` cannot produce tokens — a real `ModelContext` needs
/// a model, a tokenizer and a Metal device, which is precisely what the fake
/// exists to avoid. So these tests assert **state-machine behaviour**: the busy
/// flag, session caching, cancellation and teardown. They deliberately do not
/// assert on generated text.
///
/// This file previously assumed the fake could stream tokens. It could not, and
/// the container answered by trapping, which killed the test runner — six
/// restarts per full run, with all four tests here lost rather than reported.
/// The container now throws instead, so the runtime's failure epilogue runs and
/// can be asserted on: clearing `isGenerating`, `activeSession` and `activeTask`
/// after a failed generation is real production behaviour worth covering.
final class MLXHardeningTests: XCTestCase {

    var fakeLoader: FakeMLXLoader!
    var runtime: MLXRuntime!

    override func setUp() {
        super.setUp()
        fakeLoader = FakeMLXLoader()
        runtime = MLXRuntime(loader: fakeLoader)
    }

    override func tearDown() {
        runtime = nil
        fakeLoader = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makePrompt() -> RuntimePrompt {
        RuntimePrompt(systemPrompt: "Test", messages: [.init(role: .user, content: "Hello")])
    }

    /// Drains a generation stream, swallowing the expected failure.
    /// Returns `true` if the stream ended by throwing.
    @discardableResult
    private func drain(_ stream: AsyncThrowingStream<RuntimeEvent, Error>) async -> Bool {
        await Self.drainStream(stream)
    }

    /// Free function form so it can be called from inside a `Task { }` without
    /// capturing `self` across the isolation boundary (Swift 6 `sending`).
    private static func drainStream(_ stream: AsyncThrowingStream<RuntimeEvent, Error>) async -> Bool {
        do {
            for try await _ in stream {}
            return false
        } catch {
            return true
        }
    }

    // MARK: - Concurrency

    func testConcurrentGenerateFailsFast() async throws {
        try await runtime.loadWithProgress(model: .mockMLX, progressHandler: nil)

        let params = RuntimeParameters.balanced
        let stream1 = runtime.generate(prompt: makePrompt(), parameters: params)

        // Second request must be refused while the first holds the busy flag.
        let stream2 = runtime.generate(prompt: makePrompt(), parameters: params)
        var it2 = stream2.makeAsyncIterator()

        do {
            _ = try await it2.next()
            XCTFail("Should have failed with generationInProgress")
        } catch RuntimeError.generationInProgress {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await drain(stream1)
    }

    // MARK: - Failure epilogue

    func testFailedGenerationClearsBusyState() async throws {
        try await runtime.loadWithProgress(model: .mockMLX, progressHandler: nil)

        var params = RuntimeParameters.balanced
        params.conversationID = UUID()

        let threw = await drain(runtime.generate(prompt: makePrompt(), parameters: params))
        XCTAssertTrue(threw, "the fake container cannot generate, so the stream must surface an error")

        // The epilogue must leave the runtime reusable. Before the container
        // threw instead of trapping, this path was never executed by any test.
        XCTAssertFalse(runtime.isCurrentlyGenerating, "busy flag must be cleared after a failed generation")
        XCTAssertNil(runtime.activeSessionConversationID, "no session should be cached after a failure")
        XCTAssertNotNil(runtime.lastGenerationError, "the failure should be recorded for diagnostics")
    }

    func testRuntimeAcceptsANewGenerationAfterAFailure() async throws {
        try await runtime.loadWithProgress(model: .mockMLX, progressHandler: nil)

        await drain(runtime.generate(prompt: makePrompt(), parameters: .balanced))

        // A stuck busy flag would make this second call fail with
        // `generationInProgress` rather than the container's own error.
        let stream = runtime.generate(prompt: makePrompt(), parameters: .balanced)
        var it = stream.makeAsyncIterator()
        do {
            _ = try await it.next()
        } catch RuntimeError.generationInProgress {
            XCTFail("busy flag leaked from the previous failed generation")
        } catch {
            // Any other error is the expected container failure.
        }
    }

    // MARK: - Unload during an in-flight generation

    func testUnloadDuringGenerationCancelsAndClears() async throws {
        // Block inside `perform` so the generation is genuinely still running
        // when `unload()` arrives, instead of racing the fake's return.
        fakeLoader.containerBehaviour = .blockUntilCancelled
        try await runtime.loadWithProgress(model: .mockMLX, progressHandler: nil)

        // `generate()` spawns the runtime's worker task synchronously and sets
        // the busy flag before returning, so the generation is in flight
        // whether or not anyone consumes the stream. The stream is held in a
        // local (not iterated) purely to keep it alive — dropping it would fire
        // `onTermination` and cancel the task, which is the opposite of what
        // this test needs to set up.
        let liveStream = runtime.generate(prompt: makePrompt(), parameters: .balanced)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(runtime.isCurrentlyGenerating, "generation should be in flight before unload")

        await runtime.unload()

        XCTAssertNil(runtime.loadedModel, "unload must clear the loaded model")
        XCTAssertNil(runtime.activeSessionConversationID, "unload must drop any cached session")
        XCTAssertFalse(runtime.isCurrentlyGenerating, "unload must clear the busy flag")

        withExtendedLifetime(liveStream) {}
    }

    // MARK: - Session invalidation

    func testInvalidateSessionIsSafeWhenNoSessionIsCached() async throws {
        try await runtime.loadWithProgress(model: .mockMLX, progressHandler: nil)

        // Session caching happens only on the native `ChatSession` path, which
        // a fake container never reaches — so there is nothing cached here.
        // Invalidation must still be a well-defined no-op rather than a crash,
        // because `ConversationService` calls it on every conversation reset
        // regardless of whether a generation has run.
        await runtime.invalidateSession(for: UUID())
        XCTAssertNil(runtime.activeSessionConversationID)
    }

    func testInvalidateSessionCancelsAMatchingInFlightGeneration() async throws {
        fakeLoader.containerBehaviour = .blockUntilCancelled
        try await runtime.loadWithProgress(model: .mockMLX, progressHandler: nil)

        let conversationID = UUID()
        var params = RuntimeParameters.balanced
        params.conversationID = conversationID

        // Held, not iterated — see testUnloadDuringGenerationCancelsAndClears.
        let liveStream = runtime.generate(prompt: makePrompt(), parameters: params)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(runtime.isCurrentlyGenerating)

        await runtime.invalidateSession(for: conversationID)

        XCTAssertFalse(
            runtime.isCurrentlyGenerating,
            "invalidating the conversation being generated must cancel it and clear the busy flag"
        )

        withExtendedLifetime(liveStream) {}
    }
}
