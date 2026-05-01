import XCTest
@testable import HomeHub

final class MLXCacheTests: XCTestCase {
    
    var tempDir: URL!
    var service: LocalModelService!
    
    override func setUp() {
        super.setUp()
        // Use a unique temp directory for each test to avoid cross-talk
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HomeHubTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = LocalModelService(baseDocumentsDirectory: tempDir)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testCacheState_Missing() async {
        let state = await service.mlxCacheStates(catalogModels: [.mockMLX])
        XCTAssertEqual(state[.mockMLX.id], .missing, "Empty directory should be .missing")
    }
    
    func testCacheState_Partial_MissingWeights() async throws {
        let repoId = LocalModel.mockMLX.repoId!
        let cacheDir = tempDir.appendingPathComponent("huggingface/models/\(repoId)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        // Metadata exists
        let configURL = cacheDir.appendingPathComponent("config.json")
        try "{}".write(to: configURL, atomically: true, encoding: .utf8)
        
        let state = await service.mlxCacheStates(catalogModels: [.mockMLX])
        XCTAssertEqual(state[.mockMLX.id], .partial, "Should be .partial if metadata exists but weights do not")
    }
    
    func testCacheState_Partial_TrivialWeights() async throws {
        let repoId = LocalModel.mockMLX.repoId!
        let cacheDir = tempDir.appendingPathComponent("huggingface/models/\(repoId)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        try "{}".write(to: cacheDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        
        // Weights exist but are trivially small (< 1MB)
        let tinyData = "not a model".data(using: .utf8)!
        try tinyData.write(to: cacheDir.appendingPathComponent("model.safetensors"))
        
        let state = await service.mlxCacheStates(catalogModels: [.mockMLX])
        XCTAssertEqual(state[.mockMLX.id], .partial, "Should be .partial if weights are suspiciously small")
    }
    
    func testCacheState_Ready() async throws {
        let repoId = LocalModel.mockMLX.repoId!
        let cacheDir = tempDir.appendingPathComponent("huggingface/models/\(repoId)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        try "{}".write(to: cacheDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        
        // Create 2MB of dummy weights
        let weightsData = Data(repeating: 0, count: 2_000_000)
        try weightsData.write(to: cacheDir.appendingPathComponent("model.safetensors"))
        
        let state = await service.mlxCacheStates(catalogModels: [.mockMLX])
        XCTAssertEqual(state[.mockMLX.id], .ready, "Should be .ready if metadata and weights >= 1MB exist")
    }
    
    func testGGUFReconciliation_RemainsUnchanged() async throws {
        // Ensure that GGUF files in the legacy directory are still detected correctly
        // and don't interfere with MLX logic.
        let ggufModel = LocalModel.mockMLX // Just using it for the ID
        let supportDir = URL.applicationSupportDirectory.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        
        let ggufURL = supportDir.appendingPathComponent("\(ggufModel.id).gguf")
        let magic = Data([0x47, 0x47, 0x55, 0x46]) // GGUF magic
        let padding = Data(repeating: 0, count: 1_000_000)
        try (magic + padding).write(to: ggufURL)
        
        let installedIDs = await service.installedModelIDs()
        XCTAssertTrue(installedIDs.contains(ggufModel.id), "Legacy GGUF detection should still work")
        
        // Cleanup supportDir
        try? FileManager.default.removeItem(at: ggufURL)
    }
}
