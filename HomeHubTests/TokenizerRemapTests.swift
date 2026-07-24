import XCTest
import Hub
@testable import HomeHub

/// Coverage for the tokenizer-class remap that unblocks the Qwen family.
///
/// swift-transformers 0.1.14 throws `unsupportedTokenizer("Qwen2Tokenizer")` for
/// every Qwen 2/2.5/3 model (text and VL) because that class name isn't in its
/// registry — even though the tokenizer is ordinary byte-level BPE. The remap in
/// `SwiftTransformersTokenizerLoader` rewrites the class name onto the generic
/// driver. These tests pin the rewrite's decision table.
///
/// The remap logic is CPU-only and needs no model, so it verifies here without a
/// device. End-to-end generation quality with the remapped tokenizer is a
/// device check.
final class TokenizerRemapTests: XCTestCase {

    private func remappedClass(from tokenizerClass: String?) -> String? {
        var dict: [NSString: Any] = ["dummy" as NSString: 1]
        if let tokenizerClass {
            dict["tokenizer_class" as NSString] = tokenizerClass
        }
        let out = SwiftTransformersTokenizerLoader.remappingUnsupportedBPEClass(Config(dict))
        return out.dictionary["tokenizer_class" as NSString] as? String
    }

    func testQwen2TokenizerIsRemappedToGenericBPE() {
        // The whole point: Qwen2Tokenizer → PreTrainedTokenizer so swift-
        // transformers resolves it to BPETokenizer instead of throwing.
        XCTAssertEqual(remappedClass(from: "Qwen2Tokenizer"), "PreTrainedTokenizer")
    }

    func testFastSuffixIsHandled() {
        // swift-transformers strips a "Fast" suffix before its own lookup, so the
        // remap must match `Qwen2TokenizerFast` the same way.
        XCTAssertEqual(remappedClass(from: "Qwen2TokenizerFast"), "PreTrainedTokenizer")
    }

    func testSupportedClassesPassThroughUnchanged() {
        // Anything swift-transformers already registers must be left exactly as
        // is — the remap is not a blanket rewrite.
        for supported in ["LlamaTokenizer", "GemmaTokenizer", "GPT2Tokenizer", "PreTrainedTokenizer"] {
            XCTAssertEqual(remappedClass(from: supported), supported, "\(supported) must pass through")
        }
    }

    func testUnknownNonAllowlistedClassIsNotRewritten() {
        // A genuinely different unknown tokenizer (e.g. a SentencePiece one) must
        // NOT be coerced to byte-level BPE — that would silently mistokenise.
        // Better a clean failure than wrong tokens.
        XCTAssertEqual(remappedClass(from: "SomeSentencePieceTokenizer"), "SomeSentencePieceTokenizer")
    }

    func testMissingClassIsLeftAlone() {
        // No tokenizer_class key → nothing to remap, config returned untouched.
        XCTAssertNil(remappedClass(from: nil))
    }

    func testRemapPreservesOtherConfigKeys() {
        // The rewrite must copy the rest of the config verbatim — losing
        // add_bos_token, model_max_length, etc. would change tokenisation.
        let dict: [NSString: Any] = [
            "tokenizer_class" as NSString: "Qwen2Tokenizer",
            "add_bos_token" as NSString: false,
            "model_max_length" as NSString: 32768
        ]
        let out = SwiftTransformersTokenizerLoader.remappingUnsupportedBPEClass(Config(dict))
        XCTAssertEqual(out.dictionary["tokenizer_class" as NSString] as? String, "PreTrainedTokenizer")
        XCTAssertEqual(out.dictionary["add_bos_token" as NSString] as? Bool, false)
        XCTAssertEqual(out.dictionary["model_max_length" as NSString] as? Int, 32768)
    }
}
