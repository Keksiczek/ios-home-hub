import XCTest
@testable import HomeHub

/// Tests the pure / static surface of `HuggingFaceAPIClient`:
/// the file-filter rules and the metadata URL builder. The retry
/// loop itself isn't unit-tested here because it depends on URLSession
/// (network side effects); integration coverage lives in the manual
/// QA pass.
final class HuggingFaceAPIClientTests: XCTestCase {

    // MARK: - downloadURL

    func testDownloadURL_PercentEncodesSpaces() {
        let url = HuggingFaceAPIClient.downloadURL(
            repoId: "mlx-community/Test Model",
            filename: "config.json"
        )
        XCTAssertTrue(url.absoluteString.contains("Test%20Model"))
        XCTAssertTrue(url.absoluteString.hasSuffix("/config.json"))
    }

    // MARK: - isNeededForMLXInference

    func testIsNeededForMLXInference_AcceptsWeights() {
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("model.safetensors"))
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("model-00001-of-00002.safetensors"))
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("model.safetensors.index.json"))
    }

    func testIsNeededForMLXInference_AcceptsConfigs() {
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("config.json"))
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("tokenizer.json"))
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("tokenizer_config.json"))
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("special_tokens_map.json"))
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("generation_config.json"))
    }

    func testIsNeededForMLXInference_AcceptsBPETokenizer() {
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("merges.txt"))
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("vocab.bpe"))
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("vocab.json"))
    }

    func testIsNeededForMLXInference_AcceptsSentencePiece() {
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("tokenizer.model"))
        XCTAssertTrue(HuggingFaceAPIClient.isNeededForMLXInference("spiece.model"))
    }

    func testIsNeededForMLXInference_RejectsNonMLXWeights() {
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("pytorch_model.bin"))
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("pytorch_model-00001-of-00002.bin"))
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("flax_model.msgpack"))
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("tf_model.h5"))
    }

    func testIsNeededForMLXInference_RejectsDocsAndScripts() {
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("README.md"))
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("training.py"))
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("example.ipynb"))
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("LICENSE.txt"))
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("run.sh"))
    }

    func testIsNeededForMLXInference_RejectsRawWeights() {
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("model.bin"))
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("model.pt"))
        XCTAssertFalse(HuggingFaceAPIClient.isNeededForMLXInference("model.onnx"))
    }
}
