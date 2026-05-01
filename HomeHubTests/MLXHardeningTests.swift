import XCTest
@testable import HomeHub
import MLXLMCommon

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
    
    func testConcurrentGenerateFailsFast() async throws {
        let model = LocalModel.mockMLX
        try await runtime.loadWithProgress(model: model, progressHandler: nil)
        
        let prompt = RuntimePrompt(systemPrompt: "Test", messages: [.init(role: .user, content: "Hello")])
        let params = RuntimeParameters.balanced
        
        // Start first generation
        let stream1 = runtime.generate(prompt: prompt, parameters: params)
        let it1 = stream1.makeAsyncIterator()
        
        // Start second generation immediately
        let stream2 = runtime.generate(prompt: prompt, parameters: params)
        var it2 = stream2.makeAsyncIterator()
        
        do {
            _ = try await it2.next()
            XCTFail("Should have failed with generationInProgress")
        } catch RuntimeError.generationInProgress {
            // Success: Blocked concurrent request
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testCancelInvalidatesSession() async throws {
        let model = LocalModel.mockMLX
        try await runtime.loadWithProgress(model: model, progressHandler: nil)
        
        let prompt = RuntimePrompt(systemPrompt: "Test", messages: [.init(role: .user, content: "Hello")])
        var params = RuntimeParameters.balanced
        params.conversationID = UUID()
        
        let stream = runtime.generate(prompt: prompt, parameters: params)
        var it = stream.makeAsyncIterator()
        
        // Start and then cancel
        let task = Task {
            var tokens = 0
            while try await it.next() != nil {
                tokens += 1
                if tokens == 1 {
                    // Cancel after first token
                    break
                }
            }
        }
        
        // Give it a moment to yield first token then we break (task finishes)
        // In MLXRuntime, continuation.onTermination will cancel the task.
        try await task.value
        
        // Wait a tiny bit for the cleanup task to run
        try await Task.sleep(nanoseconds: 50_000_000)
        
        XCTAssertNil(runtime.internalActiveSessionConversationID, "Session should be invalidated after cancellation")
    }
    
    func testUnloadDuringGenerationCancelsAndClears() async throws {
        let model = LocalModel.mockMLX
        try await runtime.loadWithProgress(model: model, progressHandler: nil)
        
        let prompt = RuntimePrompt(systemPrompt: "Test", messages: [.init(role: .user, content: "Hello")])
        let params = RuntimeParameters.balanced
        
        let stream = runtime.generate(prompt: prompt, parameters: params)
        var it = stream.makeAsyncIterator()
        
        let generationTask = Task {
            do {
                while try await it.next() != nil {}
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        
        // Start generation, wait for it to be active
        try await Task.sleep(nanoseconds: 50_000_000)
        
        await runtime.unload()
        
        let wasCancelled = await generationTask.value
        XCTAssertTrue(wasCancelled, "Generation should have been cancelled by unload")
        XCTAssertNil(runtime.loadedModel)
        XCTAssertNil(runtime.internalActiveSessionConversationID)
    }
    
    func testConversationResetDiscardsSession() async throws {
        let model = LocalModel.mockMLX
        try await runtime.loadWithProgress(model: model, progressHandler: nil)
        
        let convoID = UUID()
        let prompt = RuntimePrompt(systemPrompt: "Test", messages: [.init(role: .user, content: "Hello")])
        var params = RuntimeParameters.balanced
        params.conversationID = convoID
        
        // 1. Generate to establish session
        let stream1 = runtime.generate(prompt: prompt, parameters: params)
        for try await _ in stream1 {}
        
        XCTAssertEqual(runtime.internalActiveSessionConversationID, convoID)
        
        // 2. Invalidate (Reset)
        await runtime.invalidateSession(for: convoID)
        
        XCTAssertNil(runtime.internalActiveSessionConversationID, "Session should be discarded after reset")
    }
}
