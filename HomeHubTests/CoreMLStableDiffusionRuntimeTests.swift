import XCTest
@testable import HomeHub

/// Tests for `CoreMLStableDiffusionRuntime`.
///
/// We deliberately do NOT try to load real SD weights here — that would
/// require a multi-GB download per CI run and a real Neural Engine
/// (the simulator doesn't have one). Instead we cover the deterministic
/// surface that doesn't depend on Core ML actually running:
///   1. The injected resource resolver IS consulted on load
///   2. Missing resources surface as a structured, user-readable error
///   3. Generating without a prior load surfaces `.modelNotLoaded`
///   4. The seed function is deterministic across calls (proves the
///      reproducible-by-prompt contract documented in the stub)
///   5. The seed function distributes across prompts (no constant
///      output)
///
/// Real end-to-end coverage of `pipeline.generateImages(...)` lives
/// on physical devices via the Phase 3c integration tests.
final class CoreMLStableDiffusionRuntimeTests: XCTestCase {

    // MARK: - Resource resolution

    /// Reference-typed observer the resolver closure can mutate.
    /// Required because the resolver is `@Sendable` — capturing
    /// mutable `var` locals from a Sendable closure is a strict-
    /// concurrency error. A class with `@unchecked Sendable` is the
    /// standard test-only escape hatch (no real concurrency here:
    /// the runtime calls the resolver synchronously from `load`).
    private final class ResolverObserver: @unchecked Sendable {
        var called: Bool = false
        var receivedID: String? = nil
    }

    func testLoadConsultsInjectedResolver() async {
        // Use a guaranteed-missing directory under /tmp so even on a
        // dev machine with real SD weights installed somewhere else,
        // this test gets a deterministic "missing" outcome.
        let missingURL = URL(fileURLWithPath: "/tmp/homehub-test-nonexistent-\(UUID().uuidString)")

        let observer = ResolverObserver()
        let runtime = CoreMLStableDiffusionRuntime { modelID in
            observer.called = true
            observer.receivedID = modelID
            return missingURL
        }

        do {
            try await runtime.load(modelID: "test-model")
            XCTFail("Expected load to throw for nonexistent resources")
        } catch {
            // Expected path.
        }

        XCTAssertTrue(observer.called, "Runtime must consult the injected resolver on load")
        XCTAssertEqual(observer.receivedID, "test-model", "Resolver must receive the load argument verbatim")
    }

    func testLoadWithMissingResourcesThrowsUserReadableError() async {
        let missingURL = URL(fileURLWithPath: "/tmp/homehub-test-nonexistent-\(UUID().uuidString)")
        let runtime = CoreMLStableDiffusionRuntime { _ in missingURL }

        do {
            try await runtime.load(modelID: "test-model")
            XCTFail("Expected load to throw")
        } catch let error as ImageGenerationError {
            // The error's localized description should mention the
            // model ID so users know which entry to download.
            guard case .generationFailed(let message) = error else {
                XCTFail("Expected .generationFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("test-model"), "Error must name the model so users can act on it; got: \(message)")
        } catch {
            XCTFail("Expected ImageGenerationError, got \(type(of: error)): \(error)")
        }
    }

    func testLoadedModelIDStartsNil() async {
        let runtime = CoreMLStableDiffusionRuntime()
        let id = await runtime.loadedModelID
        XCTAssertNil(id, "Fresh runtime must have no loaded model")
    }

    // MARK: - Generate without load

    func testGenerateWithoutLoadSurfacesModelNotLoaded() async {
        let runtime = CoreMLStableDiffusionRuntime()
        let stream = runtime.generate(parameters: ImageGenerationParameters(prompt: "anything"))

        var caughtError: ImageGenerationError?
        do {
            for try await event in stream {
                // We don't expect any successful events — the stream
                // should finish-with-error before any payload lands.
                if case .finished = event {
                    XCTFail("Stream produced .finished without a prior load")
                }
            }
        } catch let err as ImageGenerationError {
            caughtError = err
        } catch {
            // On builds without StableDiffusion linked, the stream
            // throws `.notImplemented` instead of `.modelNotLoaded`.
            // Both are acceptable terminal states for "no model".
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertNotNil(caughtError, "Generate without load must throw")
        if let err = caughtError {
            // Either model-not-loaded (SD module linked, no pipeline)
            // or not-implemented (SD module stripped from build) is
            // a sound failure mode.
            XCTAssertTrue(
                err == .modelNotLoaded || err == .notImplemented,
                "Got \(err), expected .modelNotLoaded or .notImplemented"
            )
        }
    }

    // MARK: - Deterministic seed contract

    func testDeterministicSeedIsStableForSamePrompt() {
        let seedA = CoreMLStableDiffusionRuntime.deterministicSeed(for: "a moonlit fox")
        let seedB = CoreMLStableDiffusionRuntime.deterministicSeed(for: "a moonlit fox")
        XCTAssertEqual(seedA, seedB, "Same prompt MUST produce the same seed across calls")
    }

    func testDeterministicSeedDiffersAcrossPrompts() {
        let seedFox = CoreMLStableDiffusionRuntime.deterministicSeed(for: "fox")
        let seedDog = CoreMLStableDiffusionRuntime.deterministicSeed(for: "dog")
        XCTAssertNotEqual(seedFox, seedDog, "Different prompts must (with overwhelming probability) produce different seeds")
    }

    func testDeterministicSeedHandlesEmptyPrompt() {
        // Edge case: the parser already filters out empty bodies, but
        // the seed function shouldn't crash on one. We just need a
        // valid UInt32 — the actual value doesn't matter.
        _ = CoreMLStableDiffusionRuntime.deterministicSeed(for: "")
    }

    func testDeterministicSeedHandlesLongPrompt() {
        // SHA256 is collision-resistant for arbitrary input length —
        // this catches regressions back to FNV-1a-style folds that
        // collide on essay-length prompts.
        let long1 = String(repeating: "a cat in a hat with a bat at a flat ", count: 50)
        let long2 = String(repeating: "a dog in a fog on a log on a hog ", count: 50)
        let seed1 = CoreMLStableDiffusionRuntime.deterministicSeed(for: long1)
        let seed2 = CoreMLStableDiffusionRuntime.deterministicSeed(for: long2)
        XCTAssertNotEqual(seed1, seed2, "Long prompts must still resolve to distinct seeds (no length-induced collisions)")
    }

    func testDeterministicSeedIsPureFunction() {
        // Not strictly necessary given the per-prompt stability test,
        // but explicit: calling the seed function should have no
        // visible side effects. We invoke it many times in a row
        // and confirm the result is unchanged.
        let prompt = "stress test prompt"
        let baseline = CoreMLStableDiffusionRuntime.deterministicSeed(for: prompt)
        for _ in 0..<100 {
            XCTAssertEqual(
                CoreMLStableDiffusionRuntime.deterministicSeed(for: prompt),
                baseline,
                "Seed function must be pure — same input every call"
            )
        }
    }

    // MARK: - Default resource URL convention

    func testDefaultResourceURLEncodesModelID() {
        let url = CoreMLStableDiffusionRuntime.defaultResourceURL(for: "coreml-sd-2-1-base-palettized")
        // The directory layout is documented as
        // Application Support/Models/coreml-sd/<modelID>/
        XCTAssertTrue(url.path.hasSuffix("/Models/coreml-sd/coreml-sd-2-1-base-palettized"),
                      "Default URL must encode modelID under the coreml-sd subtree; got \(url.path)")
    }
}
