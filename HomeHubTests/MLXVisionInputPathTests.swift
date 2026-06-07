import XCTest
@testable import HomeHub

/// Regression coverage for `MLXRuntime.shouldUseVisionInputPath(...)`.
///
/// ## The bug this guards against
///
/// `MLXRuntime.generate(...)` chooses between two execution paths:
///   - the text-only `MLXLLM.ChatSession` path, used for native
///     `ModelContainer`s — it calls `streamResponse(images: [])`, so
///     any attached image is silently dropped; and
///   - the `UserInput` / `MLXLMCommon.generate(...)` path, which decodes
///     attachments into `UserInput.Image` tensors and feeds them to the
///     processor.
///
/// `loadModelContainer` returns a `ModelContainer` for vision-language
/// models too, so the container type alone cannot tell the two apart.
/// Before the fix, every production vision turn matched
/// `self.container as? ModelContainer`, fell into the ChatSession branch,
/// and lost the picture — the image-aware path only ran for the
/// non-`ModelContainer` mock used in tests.
///
/// The decision is now a pure predicate so the routing contract is
/// pinned here without needing a real model container or a device.
final class MLXVisionInputPathTests: XCTestCase {

    // MARK: - The one case that takes the VLM path

    func testImageOnVisionModelUsesVisionPath() {
        // The fix: an image attachment on a vision-capable model MUST
        // route to the UserInput path so the bytes reach the model.
        XCTAssertTrue(
            MLXRuntime.shouldUseVisionInputPath(
                hasImages: true,
                modelSupportsVision: true
            )
        )
    }

    // MARK: - Cases that stay on the text path

    func testTextTurnOnVisionModelUsesTextPath() {
        // No image → nothing to feed; the cheaper ChatSession path
        // (with KV-cache reuse) is correct.
        XCTAssertFalse(
            MLXRuntime.shouldUseVisionInputPath(
                hasImages: false,
                modelSupportsVision: true
            )
        )
    }

    func testImageOnTextOnlyModelDoesNotUseVisionPath() {
        // A picture on a non-vision model can't be understood; the turn
        // stays on the text path (the runtime separately emits a
        // `.visionPathNotWired` warning so the user knows the image was
        // not used). Routing it to the UserInput path would feed image
        // tensors a text-only model can't consume.
        XCTAssertFalse(
            MLXRuntime.shouldUseVisionInputPath(
                hasImages: true,
                modelSupportsVision: false
            )
        )
    }

    func testTextTurnOnTextOnlyModelUsesTextPath() {
        XCTAssertFalse(
            MLXRuntime.shouldUseVisionInputPath(
                hasImages: false,
                modelSupportsVision: false
            )
        )
    }

    // MARK: - Contract: vision path requires BOTH conditions

    func testVisionPathRequiresImageAndCapabilityTogether() {
        // Exhaustive truth table — the predicate is an AND, so only the
        // (image, vision-capable) corner is true. Pinning all four
        // corners documents that neither condition alone is sufficient.
        let cases: [(hasImages: Bool, supportsVision: Bool, expected: Bool)] = [
            (false, false, false),
            (false, true,  false),
            (true,  false, false),
            (true,  true,  true)
        ]
        for c in cases {
            XCTAssertEqual(
                MLXRuntime.shouldUseVisionInputPath(
                    hasImages: c.hasImages,
                    modelSupportsVision: c.supportsVision
                ),
                c.expected,
                "hasImages=\(c.hasImages), supportsVision=\(c.supportsVision)"
            )
        }
    }
}
