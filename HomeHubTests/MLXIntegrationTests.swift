import XCTest
@testable import HomeHub
import MLXLMCommon

final class MLXIntegrationTests: XCTestCase {
    
    var fakeLoader: FakeMLXLoader!
    var runtime: MLXRuntime!
    
    override func setUp() {
        super.setUp()
        fakeLoader = FakeMLXLoader()
        runtime = MLXRuntime(loader: fakeLoader)
    }
    
    func testLoadSuccess_TransitionsToReady() async throws {
        let model = LocalModel.mockMLX
        
        var phases: [MLXLoadPhase] = []
        try await runtime.loadWithProgress(model: model) { phase in
            phases.append(phase)
        }
        
        // MLXRuntime should set its internal loadedModel on success
        XCTAssertEqual(runtime.loadedModel?.id, model.id)
        
        // Verify we saw both phases
        let hasDownloading = phases.contains(where: { 
            if case .downloading = $0 { return true }
            return false
        })
        let hasPreparing = phases.contains(where: { 
            if case .preparing = $0 { return true }
            return false
        })
        
        XCTAssertTrue(hasDownloading, "Should have emitted downloading phase")
        XCTAssertTrue(hasPreparing, "Should have emitted preparing phase")
    }
    
    func testLoadFailure_ThrowsCorrectError() async {
        let model = LocalModel.mockMLX
        fakeLoader.behavior = .failure("Disk full")
        
        do {
            try await runtime.loadWithProgress(model: model, progressHandler: nil)
            XCTFail("Should have thrown error")
        } catch RuntimeError.initializationFailed(let reason) {
            XCTAssertTrue(reason.contains("Disk full"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        
        XCTAssertNil(runtime.loadedModel, "Model should not be loaded on failure")
    }
    
    func testLoadCancellation_CleansUp() async {
        let model = LocalModel.mockMLX
        // Set a long delay so we have time to cancel
        fakeLoader.behavior = .slowProgress(steps: 100, delay: 0.01)
        
        let task = Task {
            try await runtime.loadWithProgress(model: model, progressHandler: nil)
        }
        
        // Give it a tiny moment to start the loop
        try? await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()
        
        do {
            try await task.value
            XCTFail("Should have been cancelled")
        } catch is CancellationError {
            // Success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        XCTAssertNil(runtime.loadedModel, "Model should not be loaded after cancellation")
    }
    
    func testUnload_ClearsState() async throws {
        let model = LocalModel.mockMLX
        try await runtime.loadWithProgress(model: model, progressHandler: nil)
        XCTAssertNotNil(runtime.loadedModel)
        
        await runtime.unload()
        XCTAssertNil(runtime.loadedModel)
        XCTAssertNil(runtime.internalActiveSessionConversationID)
    }

    func testInvalidateSession_SafeToCall() async {
        // Verifies the protocol method exists and is safe to call even with no session
        await runtime.invalidateSession(for: UUID())
    }
}
