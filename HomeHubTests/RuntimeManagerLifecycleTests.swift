import XCTest
@testable import HomeHub

// MARK: - SpyLocalRuntime

/// A `LocalLLMRuntime` spy for testing lifecycle behaviour without loading
/// a real GGUF file. Records every call to `handleMemoryPressure()` and
/// `handleBackground()`, and can be configured to simulate an auto-unload.
private final class SpyLocalRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "spy"

    private var _loadedModel: LocalModel?
    var loadedModel: LocalModel? { _loadedModel }

    // --- Call counters ---
    private(set) var memoryPressureCallCount = 0
    private(set) var backgroundCallCount = 0

    /// When `true`, `handleMemoryPressure()` simulates an unload
    /// (as `LlamaCppRuntime` would when policy is `.onBackgroundOrMemoryPressure`).
    var shouldUnloadOnMemoryPressure = false

    /// When `true`, `handleBackground()` simulates an unload.
    var shouldUnloadOnBackground = false

    // --- LocalLLMRuntime ---

    func load(model: LocalModel) async throws { _loadedModel = model }
    func unload() async { _loadedModel = nil }

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(
                reason: .stop,
                stats: RuntimeStats(tokensGenerated: 0, tokensPerSecond: 0, totalDurationMs: 0)
            ))
            continuation.finish()
        }
    }

    func handleMemoryPressure() async {
        memoryPressureCallCount += 1
        if shouldUnloadOnMemoryPressure { _loadedModel = nil }
    }

    func handleBackground() async {
        backgroundCallCount += 1
        if shouldUnloadOnBackground { _loadedModel = nil }
    }
}

// MARK: - RuntimeManagerLifecycleTests

/// Verifies the full lifecycle chain:
///   HomeHubApp ─► AppContainer ─► RuntimeManager ─► LocalLLMRuntime
///
/// These tests use `SpyLocalRuntime` so no GGUF is required. They confirm:
/// 1. `RuntimeManager.handleMemoryPressure()` calls the runtime and syncs state.
/// 2. `RuntimeManager.handleBackground()` calls the runtime and syncs state.
/// 3. When the runtime does NOT auto-unload, RuntimeManager state is unchanged.
/// 4. `clearState()` is idempotent when nothing is loaded.
///
/// ## Relation to AppContainer
/// `AppContainer.handleMemoryPressure()` now delegates entirely to
/// `RuntimeManager.handleMemoryPressure()`. The routing invariant tested here
/// therefore covers the full stack that was previously tested by manual device
/// verification only.
@MainActor
final class RuntimeManagerLifecycleTests: XCTestCase {

    // MARK: - Helpers

    private func makeManager(
        loaded: Bool = true,
        unloadOnPressure: Bool = false,
        unloadOnBackground: Bool = false
    ) async -> (manager: RuntimeManager, spy: SpyLocalRuntime) {
        let spy = SpyLocalRuntime()
        spy.shouldUnloadOnMemoryPressure = unloadOnPressure
        spy.shouldUnloadOnBackground = unloadOnBackground
        let manager = RuntimeManager(runtime: spy)
        if loaded {
            // RuntimeManager.load() calls through to the runtime. In tests,
            // SpyLocalRuntime.load() succeeds without touching the xcframework.
            await manager.load(.lifecycleTestStub)
        }
        return (manager, spy)
    }

    // MARK: - Memory pressure: runtime called

    func testHandleMemoryPressureCallsRuntime() async {
        let (manager, spy) = await makeManager()
        _ = await manager.handleMemoryPressure()
        XCTAssertEqual(spy.memoryPressureCallCount, 1)
    }

    func testHandleMemoryPressureCalledEvenWithNoModelLoaded() async {
        let (manager, spy) = await makeManager(loaded: false)
        _ = await manager.handleMemoryPressure()
        XCTAssertEqual(spy.memoryPressureCallCount, 1,
                       "Runtime must be notified even when no model is loaded (it may track own state).")
    }

    // MARK: - Memory pressure: state sync when runtime unloads

    func testHandleMemoryPressureReturnsUnloadedModelWhenRuntimeUnloads() async {
        let (manager, _) = await makeManager(unloadOnPressure: true)
        let unloaded = await manager.handleMemoryPressure()
        XCTAssertNotNil(unloaded, "Should return the model that was unloaded.")
        XCTAssertEqual(unloaded?.id, LocalModel.lifecycleTestStub.id)
    }

    func testHandleMemoryPressureClearsManagerStateWhenRuntimeUnloads() async {
        let (manager, _) = await makeManager(unloadOnPressure: true)
        _ = await manager.handleMemoryPressure()
        XCTAssertNil(manager.activeModel, "activeModel must be nil after runtime auto-unload.")
        XCTAssertEqual(manager.state, .idle, "state must be .idle after runtime auto-unload.")
    }

    // MARK: - Memory pressure: state preserved when runtime keeps model

    func testHandleMemoryPressureReturnsNilWhenRuntimeKeepsModel() async {
        let (manager, _) = await makeManager(unloadOnPressure: false)
        let unloaded = await manager.handleMemoryPressure()
        XCTAssertNil(unloaded, "Should return nil when no unload occurred.")
    }

    func testHandleMemoryPressurePreservesManagerStateWhenRuntimeKeepsModel() async {
        let (manager, _) = await makeManager(unloadOnPressure: false)
        _ = await manager.handleMemoryPressure()
        XCTAssertNotNil(manager.activeModel, "activeModel must remain when runtime keeps model.")
    }

    // MARK: - Background: runtime called

    func testHandleBackgroundCallsRuntime() async {
        let (manager, spy) = await makeManager()
        _ = await manager.handleBackground()
        XCTAssertEqual(spy.backgroundCallCount, 1)
    }

    func testHandleBackgroundCalledEvenWithNoModelLoaded() async {
        let (manager, spy) = await makeManager(loaded: false)
        _ = await manager.handleBackground()
        XCTAssertEqual(spy.backgroundCallCount, 1,
                       "Runtime must receive the background event regardless of load state.")
    }

    // MARK: - Background: state sync when runtime unloads

    func testHandleBackgroundReturnsUnloadedModelWhenRuntimeUnloads() async {
        let (manager, _) = await makeManager(unloadOnBackground: true)
        let unloaded = await manager.handleBackground()
        XCTAssertNotNil(unloaded)
        XCTAssertEqual(unloaded?.id, LocalModel.lifecycleTestStub.id)
    }

    func testHandleBackgroundClearsManagerStateWhenRuntimeUnloads() async {
        let (manager, _) = await makeManager(unloadOnBackground: true)
        _ = await manager.handleBackground()
        XCTAssertNil(manager.activeModel)
        XCTAssertEqual(manager.state, .idle)
    }

    // MARK: - Background: state preserved when runtime keeps model

    func testHandleBackgroundReturnsNilWhenRuntimeKeepsModel() async {
        let (manager, _) = await makeManager(unloadOnBackground: false)
        let unloaded = await manager.handleBackground()
        XCTAssertNil(unloaded)
    }

    func testHandleBackgroundPreservesManagerStateWhenRuntimeKeepsModel() async {
        let (manager, _) = await makeManager(unloadOnBackground: false)
        _ = await manager.handleBackground()
        XCTAssertNotNil(manager.activeModel)
    }

    // MARK: - No double-unload: clearState is idempotent

    func testClearStateWhenNothingLoadedDoesNotCrash() async {
        let (manager, _) = await makeManager(loaded: false)
        manager.clearState() // first call — no model, should be a no-op
        manager.clearState() // second call — still fine
        XCTAssertNil(manager.activeModel)
        XCTAssertEqual(manager.state, .idle)
    }

    func testHandleMemoryPressureTwiceDoesNotCrash() async {
        let (manager, spy) = await makeManager(unloadOnPressure: true)
        _ = await manager.handleMemoryPressure() // first event: unloads
        _ = await manager.handleMemoryPressure() // second event: nothing loaded
        XCTAssertEqual(spy.memoryPressureCallCount, 2,
                       "Runtime should still be notified on the second event.")
        XCTAssertNil(manager.activeModel)
    }

    func testHandleBackgroundTwiceDoesNotCrash() async {
        let (manager, spy) = await makeManager(unloadOnBackground: true)
        _ = await manager.handleBackground()
        _ = await manager.handleBackground()
        XCTAssertEqual(spy.backgroundCallCount, 2)
        XCTAssertNil(manager.activeModel)
    }

    // MARK: - Both events in sequence

    func testMemoryPressureThenBackgroundBothNotifyRuntime() async {
        let (manager, spy) = await makeManager(
            unloadOnPressure: false,
            unloadOnBackground: true
        )
        _ = await manager.handleMemoryPressure()
        _ = await manager.handleBackground()
        XCTAssertEqual(spy.memoryPressureCallCount, 1)
        XCTAssertEqual(spy.backgroundCallCount, 1)
        XCTAssertNil(manager.activeModel, "Background event should have triggered unload.")
    }
}

// MARK: - Test fixture

private extension LocalModel {
    static let lifecycleTestStub = LocalModel(
        id: "lifecycle-test-stub",
        displayName: "Lifecycle Test Model",
        family: "llama",
        parameterCount: "1B",
        quantization: "q4",
        sizeBytes: 1_000_000,
        contextLength: 512,
        downloadURL: URL(string: "https://example.com/model.gguf")!,
        sha256: nil,
        installState: .installed(localURL: URL(fileURLWithPath: "/tmp/lifecycle-test.gguf")),
        recommendedFor: [.iPhone],
        license: "MIT"
    )
}
