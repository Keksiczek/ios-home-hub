import XCTest
@testable import HomeHub

/// Tests for `LlamaRuntimeActor` state management.
///
/// ## What these tests cover
///
/// Because `LlamaContextHandle.load` is a stub that always throws, we
/// cannot test a successful load without a real xcframework. The tests
/// therefore verify:
///
/// - Initial state (clean slate)
/// - `borrowForGeneration` error paths
/// - `GenerationCancellationToken` lifecycle:
///   - Token cancelled on `unload()`
///   - Fresh token installed after `unload()` / after failed `load()`
///   - Borrow + unload race: borrowed token is cancelled
/// - Idempotent `unload` behaviour
/// - Concurrent call stress (actor serialisation safety)
///
/// ## Tests to add once the real bridge is wired in
///
/// 1. `testSuccessfulLoadSetsLoadedModelAndFreshToken` — load a real GGUF,
///    verify `loadedModel != nil`, `currentCancellationToken.isCancelled == false`.
/// 2. `testLoadThenUnloadClearsState` — load, then unload; verify both
///    `loadedModel == nil` and the token from before load is cancelled.
/// 3. `testBorrowForGenerationSucceeds` — load a model, call
///    `borrowForGeneration()`, verify the returned context and token are usable.
final class LlamaRuntimeActorTests: XCTestCase {

    // MARK: - Initial state

    func testInitialLoadedModelIsNil() async {
        let actor = LlamaRuntimeActor()
        let model = await actor.loadedModel
        XCTAssertNil(model, "A freshly-created actor must have no loaded model.")
    }

    func testInitialTokenIsNotCancelled() async {
        let actor = LlamaRuntimeActor()
        let token = await actor.currentCancellationToken
        XCTAssertFalse(token.isCancelled, "Initial token must not be pre-cancelled.")
    }

    func testBorrowThrowsWhenNothingLoaded() async {
        let actor = LlamaRuntimeActor()
        do {
            _ = try await actor.borrowForGeneration()
            XCTFail("Expected noModelLoaded.")
        } catch RuntimeError.noModelLoaded {
            // expected
        } catch {
            XCTFail("Expected RuntimeError.noModelLoaded, got \(error).")
        }
    }

    // MARK: - Load failure path (stub always throws)

    func testLoadPropagatesStubError() async {
        let actor = LlamaRuntimeActor()
        do {
            try await actor.load(model: .actorTestStub, path: "/nonexistent.gguf")
            XCTFail("Stub must throw.")
        } catch RuntimeError.underlying {
            // expected
        } catch {
            XCTFail("Expected RuntimeError.underlying, got \(error).")
        }
    }

    func testLoadedModelRemainsNilAfterFailedLoad() async {
        let actor = LlamaRuntimeActor()
        try? await actor.load(model: .actorTestStub, path: "/nonexistent.gguf")
        let loaded = await actor.loadedModel
        XCTAssertNil(loaded, "loadedModel must stay nil when load() throws.")
    }

    func testBorrowStillThrowsAfterFailedLoad() async {
        let actor = LlamaRuntimeActor()
        try? await actor.load(model: .actorTestStub, path: "/nonexistent.gguf")
        do {
            _ = try await actor.borrowForGeneration()
            XCTFail("Expected noModelLoaded.")
        } catch RuntimeError.noModelLoaded {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    // MARK: - GenerationCancellationToken lifecycle

    /// `unload()` must cancel the current token so any in-flight generation
    /// Task using that token observes `isCancelled = true` and stops decoding.
    func testUnloadCancelsCurrentToken() async {
        let actor = LlamaRuntimeActor()
        let tokenBeforeUnload = await actor.currentCancellationToken
        XCTAssertFalse(tokenBeforeUnload.isCancelled)

        await actor.unload()

        XCTAssertTrue(
            tokenBeforeUnload.isCancelled,
            "Token held by in-flight generation tasks must be cancelled after unload()."
        )
    }

    /// After `unload()`, the actor installs a fresh (non-cancelled) token
    /// so the next `load()` / generation starts with a clean slate.
    func testUnloadInstallsFreshToken() async {
        let actor = LlamaRuntimeActor()
        let originalToken = await actor.currentCancellationToken

        await actor.unload()

        let newToken = await actor.currentCancellationToken
        XCTAssertFalse(newToken.isCancelled, "New token must not be pre-cancelled.")
        XCTAssertFalse(newToken === originalToken, "New token must be a different object.")
    }

    /// After a failed `load()`, the actor replaces the token regardless of
    /// the C++ error. The new token is not cancelled, so the next generation
    /// attempt starts clean.
    func testFailedLoadInstallsFreshNonCancelledToken() async {
        let actor = LlamaRuntimeActor()
        let originalToken = await actor.currentCancellationToken

        // Trigger an unload cycle (which happens at the start of load())
        // even though the subsequent C++ load fails.
        try? await actor.load(model: .actorTestStub, path: "/nonexistent.gguf")

        let newToken = await actor.currentCancellationToken
        XCTAssertFalse(newToken === originalToken, "Load must replace the token.")
        XCTAssertFalse(newToken.isCancelled, "Token after failed load must be fresh.")
        XCTAssertTrue(originalToken.isCancelled, "Old token must be cancelled.")
    }

    /// Verifies the key cancellation-contract property:
    /// a token returned by `borrowForGeneration()` is the SAME object that
    /// `unload()` cancels. A generation Task holding it sees `isCancelled = true`.
    ///
    /// NOTE: In this test we can't actually call `borrowForGeneration()` (no
    /// model loaded), so we verify the identity guarantee via the actor's
    /// `currentCancellationToken` property, which is what `borrowForGeneration`
    /// returns alongside the context handle.
    func testBorrowTokenAndUnloadTokenAreTheSameObject() async {
        let actor = LlamaRuntimeActor()
        // Token at borrow time
        let tokenAtBorrow = await actor.currentCancellationToken
        XCTAssertFalse(tokenAtBorrow.isCancelled)

        // Simulate unload racing after borrow
        await actor.unload()

        // The token the generation Task holds must now be cancelled
        XCTAssertTrue(
            tokenAtBorrow.isCancelled,
            "The token a generation Task holds must be cancelled when unload() races."
        )
    }

    // MARK: - Idempotent unload

    func testUnloadWhenNothingLoadedDoesNotCrash() async {
        let actor = LlamaRuntimeActor()
        await actor.unload() // no-op — must not throw or crash
    }

    func testMultipleUnloadsAreIdempotent() async {
        let actor = LlamaRuntimeActor()
        await actor.unload()
        await actor.unload()
        await actor.unload()
        let model = await actor.loadedModel
        XCTAssertNil(model)
    }

    func testBorrowThrowsAfterExplicitUnload() async {
        let actor = LlamaRuntimeActor()
        await actor.unload()
        do {
            _ = try await actor.borrowForGeneration()
            XCTFail("Expected noModelLoaded.")
        } catch RuntimeError.noModelLoaded {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    // MARK: - Concurrent stress tests

    /// Fires 10 concurrent `unload()` calls. The actor must serialise them
    /// without crashing or entering an inconsistent state.
    func testConcurrentUnloadsDoNotCrash() async {
        let actor = LlamaRuntimeActor()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await actor.unload() }
            }
        }
        let model = await actor.loadedModel
        XCTAssertNil(model)
    }

    /// Concurrent `unload()` + `borrowForGeneration()` calls.
    /// All borrows must throw `noModelLoaded` (not crash) since no model is loaded.
    func testConcurrentBorrowAndUnloadDoNotCrash() async {
        let actor = LlamaRuntimeActor()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                if i.isMultiple(of: 3) {
                    group.addTask { await actor.unload() }
                } else {
                    group.addTask {
                        do {
                            _ = try await actor.borrowForGeneration()
                        } catch RuntimeError.noModelLoaded {
                            // expected
                        } catch {
                            XCTFail("Unexpected error in concurrent borrow: \(error)")
                        }
                    }
                }
            }
        }
    }

    /// Every token installed after an `unload()` must be non-cancelled.
    /// This guards against a bug where freshTokens accidentally share state.
    func testEachUnloadInstallsDistinctFreshToken() async {
        let actor = LlamaRuntimeActor()
        var collectedTokens: [GenerationCancellationToken] = []

        for _ in 0..<5 {
            let token = await actor.currentCancellationToken
            collectedTokens.append(token)
            await actor.unload()
        }

        // Last token (post final unload) should also be fresh
        let last = await actor.currentCancellationToken
        collectedTokens.append(last)

        // Every token after the first must be different from its predecessor
        for i in 1..<collectedTokens.count {
            XCTAssertFalse(
                collectedTokens[i] === collectedTokens[i - 1],
                "Token \(i) must be a distinct object from token \(i-1)."
            )
        }

        // All except the last (which is the current fresh one) must be cancelled
        for i in 0..<(collectedTokens.count - 1) {
            XCTAssertTrue(
                collectedTokens[i].isCancelled,
                "Old token \(i) must be cancelled."
            )
        }
        XCTAssertFalse(last.isCancelled, "Current token must not be pre-cancelled.")
    }
}

// MARK: - GenerationCancellationToken unit tests

/// Isolated tests for the token itself, without actor involvement.
final class GenerationCancellationTokenTests: XCTestCase {

    func testInitiallyNotCancelled() {
        let token = GenerationCancellationToken()
        XCTAssertFalse(token.isCancelled)
    }

    func testCancelSetsFlag() {
        let token = GenerationCancellationToken()
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }

    func testCancelIsIdempotent() {
        let token = GenerationCancellationToken()
        token.cancel()
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }

    func testConcurrentReadsDoNotCrash() async {
        let token = GenerationCancellationToken()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<50 {
                group.addTask { token.isCancelled }
            }
            group.addTask {
                token.cancel()
                return token.isCancelled
            }
            for await _ in group { }
        }
        XCTAssertTrue(token.isCancelled)
    }
}

// MARK: - Test fixtures

private extension LocalModel {
    static let actorTestStub = LocalModel(
        id: "actor-test-stub",
        displayName: "Actor Test Stub",
        family: "test",
        parameterCount: "1B",
        quantization: "q4",
        sizeBytes: 1_000_000,
        contextLength: 512,
        downloadURL: URL(string: "https://example.com/model.gguf")!,
        sha256: nil,
        installState: .installed(localURL: URL(fileURLWithPath: "/tmp/test.gguf")),
        recommendedFor: [.iPhone],
        license: "MIT"
    )
}
