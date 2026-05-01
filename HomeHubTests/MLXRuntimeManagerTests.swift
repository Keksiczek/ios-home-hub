import XCTest
@testable import HomeHub

@MainActor
final class MLXRuntimeManagerTests: XCTestCase {
    
    var fakeLoader: FakeMLXLoader!
    var mlxRuntime: MLXRuntime!
    var manager: RuntimeManager!
    
    override func setUp() {
        super.setUp()
        fakeLoader = FakeMLXLoader()
        mlxRuntime = MLXRuntime(loader: fakeLoader)
        // Note: RuntimeManager typically takes the RoutingRuntime, 
        // but for these tests we can pass the MLXRuntime directly to verify its specific flow.
        manager = RuntimeManager(runtime: mlxRuntime)
    }
    
    func testLoadSuccess_UpdatesState() async {
        let model = LocalModel.mockMLX
        
        await manager.load(model)
        
        XCTAssertEqual(manager.state, .ready(modelID: model.id))
        XCTAssertEqual(manager.activeModel?.id, model.id)
        XCTAssertNil(manager.mlxLoadProgress)
    }
    
    func testLoadFailure_UpdatesState() async {
        let model = LocalModel.mockMLX
        fakeLoader.behavior = .failure("Disk error")
        
        await manager.load(model)
        
        if case .failed(_, let reason) = manager.state {
            XCTAssertTrue(reason.contains("Disk error"))
        } else {
            XCTFail("State should be failed, but was \(manager.state)")
        }
        XCTAssertNil(manager.mlxLoadProgress)
    }
    
    func testLoadProgress_IsPublished() async throws {
        let model = LocalModel.mockMLX
        fakeLoader.behavior = .slowProgress(steps: 10, delay: 0.05)
        
        let task = Task {
            await manager.load(model)
        }
        
        // Give it a moment to start and emit progress
        try await Task.sleep(nanoseconds: 100_000_000)
        
        XCTAssertNotNil(manager.mlxLoadProgress, "Progress should be visible while loading")
        
        await task.value
        XCTAssertNil(manager.mlxLoadProgress, "Progress should be cleared after success")
    }
    
    func testCancelLoad_CleansUp() async throws {
        let model = LocalModel.mockMLX
        fakeLoader.behavior = .slowProgress(steps: 100, delay: 0.1)
        
        let task = Task {
            await manager.load(model)
        }
        
        // Wait for it to start
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(manager.mlxLoadProgress)
        
        manager.cancelMLXLoad()
        
        await task.value
        XCTAssertNil(manager.mlxLoadProgress)
        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.activeModel)
    }
}
