import XCTest
@testable import HomeHub

/// Tests for `LlamaRuntimeActor` state management.
///
/// Because `LlamaContextHandle.load` is still a stub that always throws, we
/// cannot test a successful load path without a real xcframework. These tests
/// therefore cover:
///
/// - Initial state (empty)
/// - Error propagation from a failed load
/// - Invariants that must hold after a failed load
/// - Idempotent unload behaviour
/// - `contextSnapshot` error path when no model is loaded
///
/// Two tests worth adding once the real bridge is wired in (tracked as TODOs):
/// 1. Successful load → `loadedModel` non-nil → `contextSnapshot()` succeeds
/// 2. Load followed by unload → `loadedModel` nil → `contextSnapshot()` throws
final class LlamaRuntimeActorTests: XCTestCase {

    // MARK: - Initial state

    func testInitialLoadedModelIsNil() async {
        let actor = LlamaRuntimeActor()
        let model = await actor.loadedModel
        XCTAssertNil(model, "A freshly-created actor must have no loaded model.")
    }

    func testContextSnapshotThrowsWhenNothingLoaded() async {
        let actor = LlamaRuntimeActor()
        do {
            _ = try await actor.contextSnapshot()
            XCTFail("Expected noModelLoaded to be thrown.")
        } catch RuntimeError.noModelLoaded {
            // expected
        } catch {
            XCTFail("Expected RuntimeError.noModelLoaded, got \(error).")
        }
    }

    // MARK: - Load failure (stub always throws)

    func testLoadPropagatesStubError() async {
        let actor = LlamaRuntimeActor()
        let model = LocalModel.actorTestStub

        do {
            try await actor.load(model: model, path: "/nonexistent/model.gguf")
            XCTFail("Stub must throw.")
        } catch RuntimeError.underlying {
            // expected — stub always throws .underlying
        } catch {
            XCTFail("Expected RuntimeError.underlying, got \(error).")
        }
    }

    func testLoadedModelRemainsNilAfterFailedLoad() async {
        let actor = LlamaRuntimeActor()
        let model = LocalModel.actorTestStub

        try? await actor.load(model: model, path: "/nonexistent.gguf")

        let loaded = await actor.loadedModel
        XCTAssertNil(loaded, "loadedModel must stay nil when load() throws.")
    }

    func testContextSnapshotStillThrowsAfterFailedLoad() async {
        let actor = LlamaRuntimeActor()
        let model = LocalModel.actorTestStub

        try? await actor.load(model: model, path: "/nonexistent.gguf")

        do {
            _ = try await actor.contextSnapshot()
            XCTFail("Expected noModelLoaded after a failed load.")
        } catch RuntimeError.noModelLoaded {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    // MARK: - Unload

    func testUnloadWhenNothingLoadedDoesNotCrash() async {
        let actor = LlamaRuntimeActor()
        // Must not throw or crash.
        await actor.unload()
    }

    func testUnloadIsIdempotent() async {
        let actor = LlamaRuntimeActor()
        await actor.unload()
        await actor.unload()
        let model = await actor.loadedModel
        XCTAssertNil(model)
    }

    func testContextSnapshotThrowsAfterUnload() async {
        let actor = LlamaRuntimeActor()
        await actor.unload()

        do {
            _ = try await actor.contextSnapshot()
            XCTFail("Expected noModelLoaded after unload.")
        } catch RuntimeError.noModelLoaded {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    // MARK: - Concurrent calls (smoke test)

    func testConcurrentUnloadsDoNotCrash() async {
        let actor = LlamaRuntimeActor()

        // Fire several concurrent unload calls; the actor must serialise them
        // without crashing or entering an inconsistent state.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await actor.unload() }
            }
        }

        let model = await actor.loadedModel
        XCTAssertNil(model)
    }
}

// MARK: - Test fixtures

private extension LocalModel {
    /// Minimal model fixture for actor tests.
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
