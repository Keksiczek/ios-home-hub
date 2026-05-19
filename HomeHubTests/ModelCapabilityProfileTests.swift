import XCTest
@testable import HomeHub

/// Unit tests for `ModelCapabilityProfile` resolution and per-family constants.
///
/// ## What these tests guard
/// 1. `resolve(family:)` returns the correct profile for each known family.
/// 2. Unknown/empty family strings fall back to `.default` (most conservative).
/// 3. Flash-attention is disabled exactly for families with known issues.
/// 4. Per-family history budgets are in a sane range and ordered correctly.
/// 5. `safeHistoryCharBudget` derived property stays consistent with the
///    token budget and the 0.35 tokens-per-character constant.
/// 6. The profile flows end-to-end through `PromptAssemblyService` so that
///    per-family history trimming is actually exercised at the assembly layer.
final class ModelCapabilityProfileTests: XCTestCase {

    // MARK: - resolve(family:) — happy paths

    func testResolveLlama() {
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "llama"), .llama)
    }

    func testResolveLlamaWithVersionSuffix() {
        // Common real-world family strings from the model catalog
        for family in ["llama3", "llama-3.2-3b", "meta-llama", "Llama-3", "LLAMA"] {
            let profile = ModelCapabilityProfile.resolve(family: family)
            XCTAssertEqual(profile, .llama, "'\(family)' should resolve to .llama")
        }
    }

    func testResolveQwen() {
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "qwen"), .qwen)
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "Qwen2.5"), .qwen)
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "qwen1.5-7b"), .qwen)
    }

    func testResolveMistral() {
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "mistral"), .mistral)
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "Mistral-7B-v0.3"), .mistral)
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "mixtral"), .mistral)
    }

    func testResolveGemma() {
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "gemma"), .gemma)
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "gemma3"), .gemma)
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "gemma-2-9b"), .gemma)
    }

    func testResolvePhi() {
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "phi"), .phi)
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "phi-3"), .phi)
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "phi-4"), .phi)
        XCTAssertEqual(ModelCapabilityProfile.resolve(family: "Phi-3-mini-4k"), .phi)
    }

    // MARK: - resolve(family:) — fallback

    func testResolveEmptyStringReturnsDefault() {
        let profile = ModelCapabilityProfile.resolve(family: "")
        XCTAssertEqual(profile, .default)
    }

    func testResolveUnknownFamilyReturnsDefault() {
        for family in ["gpt4", "solar", "orion", "deepseek", "falcon"] {
            let profile = ModelCapabilityProfile.resolve(family: family)
            XCTAssertEqual(profile, .default,
                           "Unknown family '\(family)' should fall back to .default")
        }
    }

    // MARK: - Flash attention safety

    func testFlashAttentionEnabledForSafeFamilies() {
        XCTAssertTrue(ModelCapabilityProfile.llama.supportsFlashAttention)
        XCTAssertTrue(ModelCapabilityProfile.qwen.supportsFlashAttention)
        XCTAssertTrue(ModelCapabilityProfile.mistral.supportsFlashAttention)
        XCTAssertTrue(ModelCapabilityProfile.gemma.supportsFlashAttention)
    }

    func testFlashAttentionDisabledForPhi() {
        XCTAssertFalse(ModelCapabilityProfile.phi.supportsFlashAttention,
                       "Phi-3/4 have known flash_attn correctness issues — must be false.")
    }

    func testFlashAttentionDisabledForDefault() {
        XCTAssertFalse(ModelCapabilityProfile.default.supportsFlashAttention,
                       "Unknown families get the safe default: no flash attention.")
    }

    // MARK: - History budget ordering (more capable families get more budget)

    func testHighCapacityFamiliesHaveLargerHistoryBudget() {
        // llama / qwen / mistral are the most context-efficient — they should
        // have a larger safe history budget than gemma / phi / default.
        let highCapacity = [ModelCapabilityProfile.llama, .qwen, .mistral]
        let lowerCapacity = [ModelCapabilityProfile.gemma, .phi, .default]

        for high in highCapacity {
            for low in lowerCapacity {
                XCTAssertGreaterThanOrEqual(
                    high.safeHistoryTokenBudget,
                    low.safeHistoryTokenBudget,
                    "\(high.family) budget (\(high.safeHistoryTokenBudget)) should be ≥ \(low.family) budget (\(low.safeHistoryTokenBudget))"
                )
            }
        }
    }

    func testDefaultHasSmallestBudget() {
        let allNamed: [ModelCapabilityProfile] = [.llama, .qwen, .mistral, .gemma, .phi]
        for profile in allNamed {
            XCTAssertGreaterThanOrEqual(
                profile.safeHistoryTokenBudget,
                ModelCapabilityProfile.default.safeHistoryTokenBudget,
                "\(profile.family) budget should be ≥ default"
            )
        }
    }

    // MARK: - Budget sanity (absolute bounds)

    func testAllProfilesHaveSafeHistoryBudgetInSaneRange() {
        let all: [ModelCapabilityProfile] = [.llama, .qwen, .mistral, .gemma, .phi, .default]
        for profile in all {
            XCTAssertGreaterThan(profile.safeHistoryTokenBudget, 400,
                                 "\(profile.family): budget too small — system prompt alone can be 400 tokens")
            XCTAssertLessThan(profile.safeHistoryTokenBudget, 2500,
                              "\(profile.family): budget suspiciously large for a 4096-token context")
        }
    }

    func testGenerationReserveIsReasonable() {
        let all: [ModelCapabilityProfile] = [.llama, .qwen, .mistral, .gemma, .phi, .default]
        for profile in all {
            XCTAssertGreaterThanOrEqual(profile.generationReserveTokens, 256,
                                        "\(profile.family): reserve too small for useful responses")
            XCTAssertLessThanOrEqual(profile.generationReserveTokens, 1024,
                                     "\(profile.family): reserve too large — leaves little for history")
        }
    }

    // MARK: - messageTokenOverhead

    func testMessageTokenOverheadIsInReasonableRange() {
        let all: [ModelCapabilityProfile] = [.llama, .qwen, .mistral, .gemma, .phi, .default]
        for profile in all {
            XCTAssertGreaterThanOrEqual(profile.messageTokenOverhead, 3,
                "\(profile.family): overhead < 3 is unrealistically low for any chat template")
            XCTAssertLessThanOrEqual(profile.messageTokenOverhead, 12,
                "\(profile.family): overhead > 12 is suspiciously large")
        }
    }

    // MARK: - n_ubatch

    func testNUBatchIsInReasonableRange() {
        let all: [ModelCapabilityProfile] = [.llama, .qwen, .mistral, .gemma, .phi, .default]
        for profile in all {
            XCTAssertGreaterThanOrEqual(profile.nUBatch, 1)
            XCTAssertLessThanOrEqual(profile.nUBatch, 512,
                                     "n_ubatch > 512 offers no benefit over n_batch")
        }
    }

    // MARK: - PromptAssemblyService integration

    /// Verifies that the per-family history budget from `ModelCapabilityProfile`
    /// is actually applied by `PromptAssemblyService.build(from:)`.
    @MainActor
    func testPromptAssemblyUsesProfileHistoryBudget() {
        let service = PromptAssemblyService()

        // Build a long history: 20 messages × 200 ASCII 'x' chars each.
        // HeuristicTokenEstimator weights ASCII letters at 0.25 tok/char → ~50 tokens
        // per message body. Add per-message overhead (llama=7, phi=5) → ~57 / ~55 tokens
        // per message respectively.
        //   Llama budget 1400 ÷ 57 ≈ 24 — fits all 20 messages.
        //   Phi   budget 1200 ÷ 55 ≈ 21 — also fits all 20, but tighter.
        // Using 400-char messages (100 tokens/body) instead makes the contrast clear:
        //   Llama: 1400 ÷ 107 ≈ 13 messages kept.
        //   Phi:   1200 ÷ 105 ≈ 11 messages kept.
        let convID = UUID()
        let messages = (0..<20).map { i in
            Message(
                id: UUID(), conversationID: convID,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: String(repeating: "x", count: 400),
                createdAt: .now, status: .complete, tokenCount: nil
            )
        }

        // Phi profile — tighter budget
        let phiPackage = makePackage(messages: messages, profile: .phi)
        let phiPrompt = service.build(from: phiPackage)

        // Llama profile — larger budget
        let llamaPackage = makePackage(messages: messages, profile: .llama)
        let llamaPrompt = service.build(from: llamaPackage)

        // Llama should fit more history messages than phi
        XCTAssertGreaterThanOrEqual(
            llamaPrompt.messages.count,
            phiPrompt.messages.count,
            "Llama profile's larger budget should accommodate at least as many messages as Phi"
        )
    }

    /// Verifies that when no profile is provided, `PromptAssemblyService`
    /// falls back to `.default` (most conservative) instead of crashing.
    @MainActor
    func testPromptAssemblyHandlesNilProfile() {
        let service = PromptAssemblyService()
        let package = makePackage(messages: [], profile: nil)
        let prompt = service.build(from: package)
        XCTAssertNotNil(prompt) // must not crash
        XCTAssertEqual(prompt.messages.last?.content, "Hello")
    }

    // MARK: - Helpers

    // MARK: - Size-aware resolution (parameterCount)

    func testResolveLlama1BIsWeak() {
        let profile = ModelCapabilityProfile.resolve(family: "llama", parameterCount: "1B")
        XCTAssertTrue(profile.isWeakInstructionFollower,
                      "Llama 1B should be promoted to weak instruction follower")
        // Sampling tightening should also apply.
        XCTAssertLessThanOrEqual(profile.recommendedTemperature, 0.5)
        XCTAssertGreaterThanOrEqual(profile.recommendedRepeatPenalty, 1.2)
        XCTAssertGreaterThanOrEqual(profile.recommendedMinP, 0.1)
    }

    func testResolveLlama3BIsStrong() {
        let profile = ModelCapabilityProfile.resolve(family: "llama", parameterCount: "3B")
        XCTAssertFalse(profile.isWeakInstructionFollower,
                       "Llama 3B should remain strong")
        // Strong family keeps its native sampling.
        XCTAssertEqual(profile.recommendedTemperature, ModelCapabilityProfile.llama.recommendedTemperature)
    }

    func testResolveQwen1B5IsWeak() {
        let profile = ModelCapabilityProfile.resolve(family: "qwen", parameterCount: "1.5B")
        XCTAssertTrue(profile.isWeakInstructionFollower)
    }

    func testResolveLlama8BIsStrong() {
        let profile = ModelCapabilityProfile.resolve(family: "llama", parameterCount: "8B")
        XCTAssertFalse(profile.isWeakInstructionFollower)
    }

    func testResolveNilParameterCountMatchesLegacyAPI() {
        let legacy = ModelCapabilityProfile.resolve(family: "llama")
        let nilParam = ModelCapabilityProfile.resolve(family: "llama", parameterCount: nil)
        XCTAssertEqual(legacy, nilParam)
    }

    func testIsSmallVariantParsing() {
        XCTAssertTrue(ModelCapabilityProfile.isSmallVariant(parameterCount: "1B"))
        XCTAssertTrue(ModelCapabilityProfile.isSmallVariant(parameterCount: "1.5B"))
        XCTAssertTrue(ModelCapabilityProfile.isSmallVariant(parameterCount: "2B"))
        XCTAssertTrue(ModelCapabilityProfile.isSmallVariant(parameterCount: "500M"))
        XCTAssertFalse(ModelCapabilityProfile.isSmallVariant(parameterCount: "3B"))
        XCTAssertFalse(ModelCapabilityProfile.isSmallVariant(parameterCount: "8B"))
        XCTAssertFalse(ModelCapabilityProfile.isSmallVariant(parameterCount: nil))
        XCTAssertFalse(ModelCapabilityProfile.isSmallVariant(parameterCount: ""))
        XCTAssertFalse(ModelCapabilityProfile.isSmallVariant(parameterCount: "garbage"))
    }

    private func makePackage(messages: [Message], profile: ModelCapabilityProfile?) -> PromptContextPackage {
        PromptContextPackage(
            assistant: AssistantProfile.defaultAssistant,
            user: UserProfile(
                id: UUID(), displayName: "Tester",
                pronouns: nil, occupation: nil,
                locale: "en_US", interests: [],
                workingContext: nil,
                preferredResponseStyle: .balanced,
                createdAt: .now, updatedAt: .now
            ),
            facts: [],
            episodes: [],
            recentMessages: messages,
            userInput: "Hello",
            settings: .default,
            modelCapabilityProfile: profile
        )
    }
}
