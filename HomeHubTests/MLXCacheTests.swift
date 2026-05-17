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
        XCTAssertEqual(state[LocalModel.mockMLX.id], .missing, "Empty directory should be .missing")
    }
    
    func testCacheState_Partial_MissingWeights() async throws {
        let repoId = LocalModel.mockMLX.repoId!
        let cacheDir = tempDir.appendingPathComponent("huggingface/models/\(repoId)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Metadata + tokenizer exist, but no weights — the canonical
        // "download was interrupted before the .safetensors shard
        // finished" shape.
        try "{}".write(to: cacheDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: cacheDir.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        let state = await service.mlxCacheStates(catalogModels: [.mockMLX])
        XCTAssertEqual(state[LocalModel.mockMLX.id], .partial, "Should be .partial if metadata exists but weights do not")
    }

    func testCacheState_Missing_NoTokenizer() async throws {
        let repoId = LocalModel.mockMLX.repoId!
        let cacheDir = tempDir.appendingPathComponent("huggingface/models/\(repoId)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Only config — no tokenizer. The runtime can't bridge this
        // into MLXLMCommon, so we classify as .missing.
        try "{}".write(to: cacheDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let state = await service.mlxCacheStates(catalogModels: [.mockMLX])
        XCTAssertEqual(state[LocalModel.mockMLX.id], .missing, "Should be .missing without a tokenizer artefact")
    }

    func testCacheState_Partial_TrivialWeights() async throws {
        let repoId = LocalModel.mockMLX.repoId!
        let cacheDir = tempDir.appendingPathComponent("huggingface/models/\(repoId)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        try "{}".write(to: cacheDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: cacheDir.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        // Weights exist but are trivially small (< 1MB)
        let tinyData = "not a model".data(using: .utf8)!
        try tinyData.write(to: cacheDir.appendingPathComponent("model.safetensors"))

        let state = await service.mlxCacheStates(catalogModels: [.mockMLX])
        XCTAssertEqual(state[LocalModel.mockMLX.id], .partial, "Should be .partial if weights are suspiciously small")
    }

    func testCacheState_Ready() async throws {
        let repoId = LocalModel.mockMLX.repoId!
        let cacheDir = tempDir.appendingPathComponent("huggingface/models/\(repoId)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        try "{}".write(to: cacheDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: cacheDir.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        // Create 2MB of dummy weights
        let weightsData = Data(repeating: 0, count: 2_000_000)
        try weightsData.write(to: cacheDir.appendingPathComponent("model.safetensors"))

        let state = await service.mlxCacheStates(catalogModels: [.mockMLX])
        XCTAssertEqual(state[LocalModel.mockMLX.id], .ready, "Should be .ready if metadata and weights >= 1MB exist")
    }

    // MARK: - Detailed inspection

    func testInspectMLXCache_FailureReason_MissingTokenizerAndWeights() throws {
        let cacheDir = tempDir.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try "{}".write(to: cacheDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let inspection = LocalModelService.inspectMLXCache(at: cacheDir)
        XCTAssertEqual(inspection.state, .missing)
        XCTAssertFalse(inspection.hasTokenizer)
        XCTAssertFalse(inspection.hasWeights)
        XCTAssertTrue(inspection.hasConfig)
        XCTAssertNotNil(inspection.failureReason)
        XCTAssertTrue(inspection.failureReason!.contains("tokenizer"),
                      "Failure reason should mention the missing tokenizer (\(inspection.failureReason!))")
    }

    func testInspectMLXCache_Ready_NoFailureReason() throws {
        let cacheDir = tempDir.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try "{}".write(to: cacheDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: cacheDir.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 2_000_000)
            .write(to: cacheDir.appendingPathComponent("model.safetensors"))

        let inspection = LocalModelService.inspectMLXCache(at: cacheDir)
        XCTAssertEqual(inspection.state, .ready)
        XCTAssertNil(inspection.failureReason)
        XCTAssertGreaterThanOrEqual(inspection.totalWeightsBytes, 2_000_000)
    }
    
    // MARK: - Family detection from config.json
    //
    // Backs the user-added MLX promotion path: after install the
    // catalog upgrades family "Custom" → detected family so the
    // chat-template fallback in SwiftTransformersTokenizerBridge picks
    // the right render path.

    func testDetectMLXFamily_Llama() throws {
        let url = tempDir.appendingPathComponent("config.json")
        try #"{"architectures":["LlamaForCausalLM"],"model_type":"llama"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalModelService.detectMLXFamily(configURL: url), "Llama")
    }

    func testDetectMLXFamily_Gemma3() throws {
        let url = tempDir.appendingPathComponent("config.json")
        try #"{"architectures":["Gemma3ForCausalLM"],"model_type":"gemma3"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalModelService.detectMLXFamily(configURL: url), "Gemma3")
    }

    func testDetectMLXFamily_Qwen2() throws {
        let url = tempDir.appendingPathComponent("config.json")
        try #"{"model_type":"qwen2"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalModelService.detectMLXFamily(configURL: url), "Qwen")
    }

    func testDetectMLXFamily_UnknownArchitectureReturnsNil() throws {
        let url = tempDir.appendingPathComponent("config.json")
        try #"{"architectures":["NoSuchArch"]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(LocalModelService.detectMLXFamily(configURL: url))
    }

    func testDetectMLXFamily_MissingConfigReturnsNil() {
        let url = tempDir.appendingPathComponent("does-not-exist.json")
        XCTAssertNil(LocalModelService.detectMLXFamily(configURL: url))
    }

    func testInspectMLXCache_PopulatesDetectedFamily() throws {
        let repoId = "mlx-community/test-llama"
        let cacheDir = tempDir
            .appendingPathComponent("huggingface/models/\(repoId)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try #"{"architectures":["LlamaForCausalLM"]}"#
            .write(to: cacheDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: cacheDir.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 2_000_000)
            .write(to: cacheDir.appendingPathComponent("model.safetensors"))

        let inspection = LocalModelService.inspectMLXCache(at: cacheDir)
        XCTAssertEqual(inspection.state, .ready)
        XCTAssertEqual(inspection.detectedFamily, "Llama")
    }

    // MARK: - Orphan enumeration
    //
    // Backs the bootstrap cleanup pass that reclaims disk from cache
    // directories whose catalog entries were deleted (e.g. user
    // cancelled mid-download then removed the model).

    func testEnumerateMLXCacheRepos_FindsOrgRepoPairs() async throws {
        let root = tempDir.appendingPathComponent("huggingface/models")
        let a = root.appendingPathComponent("orgA/repo1")
        let b = root.appendingPathComponent("orgA/repo2")
        let c = root.appendingPathComponent("orgB/repoX")
        for url in [a, b, c] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let repos = Set(await service.enumerateMLXCacheRepos())
        XCTAssertEqual(repos, ["orgA/repo1", "orgA/repo2", "orgB/repoX"])
    }

    func testEnumerateMLXCacheRepos_EmptyWhenRootMissing() async {
        let repos = await service.enumerateMLXCacheRepos()
        XCTAssertTrue(repos.isEmpty)
    }

    func testMLXCacheSizeBytes_SumsAllShards() async throws {
        let repoId = "mlx-community/size-test"
        let cacheDir = tempDir.appendingPathComponent("huggingface/models/\(repoId)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000)
            .write(to: cacheDir.appendingPathComponent("part1.safetensors"))
        try Data(repeating: 2, count: 2_000)
            .write(to: cacheDir.appendingPathComponent("part2.safetensors"))
        let size = await service.mlxCacheSizeBytes(for: repoId)
        XCTAssertEqual(size, 3_000)
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
