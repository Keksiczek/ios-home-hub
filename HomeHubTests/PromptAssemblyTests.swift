import XCTest
@testable import HomeHub

@MainActor
final class PromptAssemblyTests: XCTestCase {

    private let service = PromptAssemblyService()

    private func makePackage(
        facts: [MemoryFact] = [],
        episodes: [MemoryEpisode] = [],
        userInput: String = "Hello"
    ) -> PromptContextPackage {
        PromptContextPackage(
            assistant: AssistantProfile.defaultAssistant,
            user: UserProfile(
                id: UUID(),
                displayName: "Alex",
                pronouns: "they/them",
                occupation: "Product designer",
                locale: "en_US",
                interests: ["typography"],
                workingContext: "Launching a meditation app",
                preferredResponseStyle: .balanced,
                createdAt: .now,
                updatedAt: .now
            ),
            facts: facts,
            episodes: episodes,
            recentMessages: [],
            userInput: userInput,
            settings: .default
        )
    }

    // MARK: - Layered prompt structure

    func testSystemPromptContainsAssistantPersona() {
        let package = makePackage()
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains(AssistantProfile.defaultAssistant.systemPromptBase))
    }

    func testSystemPromptContainsUserProfile() {
        let package = makePackage()
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("Name: Alex"))
        XCTAssertTrue(prompt.systemPrompt.contains("Pronouns: they/them"))
        XCTAssertTrue(prompt.systemPrompt.contains("Work: Product designer"))
    }

    func testSystemPromptContainsFactsWhenPresent() {
        let facts = [
            MemoryFact(id: UUID(), content: "Prefers concise replies",
                       category: .preferences, source: .userManual,
                       confidence: 0.95, createdAt: .now, lastUsedAt: nil,
                       pinned: true, disabled: false)
        ]
        let package = makePackage(facts: facts)
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("Remembered facts"))
        XCTAssertTrue(prompt.systemPrompt.contains("Prefers concise replies"))
    }

    func testSystemPromptOmitsFactsSectionWhenEmpty() {
        let package = makePackage(facts: [])
        let prompt = service.build(from: package)

        XCTAssertFalse(prompt.systemPrompt.contains("Remembered facts"))
    }

    func testSystemPromptContainsEpisodesWhenPresent() {
        let episodes = [
            MemoryEpisode(id: UUID(),
                          summary: "Working on SwiftUI migration",
                          sourceConversationID: UUID(),
                          sourceMessageID: UUID(),
                          createdAt: .now, lastRelevantAt: nil,
                          approved: true, disabled: false,
                          extractionMethod: .structured)
        ]
        let package = makePackage(episodes: episodes)
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("Recent context"))
        XCTAssertTrue(prompt.systemPrompt.contains("Working on SwiftUI migration"))
    }

    func testSystemPromptOmitsEpisodesSectionWhenEmpty() {
        let package = makePackage(episodes: [])
        let prompt = service.build(from: package)

        XCTAssertFalse(prompt.systemPrompt.contains("Recent context"))
    }

    func testSystemPromptContainsPrivacyGuardrails() {
        let package = makePackage()
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("Never fabricate personal details"))
        XCTAssertTrue(prompt.systemPrompt.contains("on-device"))
    }

    // MARK: - Layer ordering

    func testLayerOrdering() {
        let facts = [
            MemoryFact(id: UUID(), content: "Fact marker content here",
                       category: .work, source: .userManual,
                       confidence: 1.0, createdAt: .now, lastUsedAt: nil,
                       pinned: false, disabled: false)
        ]
        let episodes = [
            MemoryEpisode(id: UUID(),
                          summary: "Episode marker content here",
                          sourceConversationID: UUID(),
                          sourceMessageID: UUID(),
                          createdAt: .now, lastRelevantAt: nil,
                          approved: true, disabled: false,
                          extractionMethod: .structured)
        ]
        let package = makePackage(facts: facts, episodes: episodes)
        let prompt = service.build(from: package)

        // Ordering is asserted WITHIN each half, not across the merged legacy
        // string.
        //
        // The prompt is assembled in two halves: a `stableSystemPrompt` that
        // stays byte-identical across turns (so the KV-cache prefix survives)
        // and a `volatileSystemPrompt` that changes every turn. The profile and
        // the privacy guardrail are stable; facts and episodes are volatile.
        //
        // The legacy `systemPrompt` getter concatenates `stable + volatile`, so
        // the guardrail now precedes episodes in that merged string — which is
        // why the old cross-half assertion (`episodes < guardrails`) fails. The
        // guardrail's stable placement is deliberate and must not be reverted
        // to satisfy a test: in production the volatile half is not appended to
        // the system prompt at all, `MLXRuntime` injects it into the user turn
        // inside `<context>`. Asserting across the halves was measuring an
        // artifact of the legacy getter, not the assembly contract.
        let stable = prompt.stableSystemPrompt
        let volatileHalf = prompt.volatileSystemPrompt

        let profileRange = stable.range(of: "About the user")!
        let guardrailsRange = stable.range(of: "Never fabricate")!
        XCTAssertTrue(
            profileRange.lowerBound < guardrailsRange.lowerBound,
            "stable half: profile must precede the privacy guardrail"
        )

        let factsRange = volatileHalf.range(of: "Remembered facts")!
        let episodesRange = volatileHalf.range(of: "Recent context")!
        XCTAssertTrue(
            factsRange.lowerBound < episodesRange.lowerBound,
            "volatile half: facts must precede episodes"
        )
    }

    // MARK: - Limits

    func testFactsAreCappedAtEight() {
        let facts = (0..<20).map { i in
            MemoryFact(id: UUID(), content: "Fact \(i)",
                       category: .other, source: .userManual,
                       confidence: 1.0, createdAt: .now, lastUsedAt: nil,
                       pinned: false, disabled: false)
        }
        let package = makePackage(facts: facts)
        let prompt = service.build(from: package)

        // PromptAssemblyService caps facts at prefix(8) → 0-7 included.
        XCTAssertTrue(prompt.systemPrompt.contains("Fact 7"))
        XCTAssertFalse(prompt.systemPrompt.contains("Fact 8"))
    }

    func testEpisodesAreCappedAtThree() {
        let episodes = (0..<10).map { i in
            MemoryEpisode(id: UUID(),
                          summary: "Episode \(i)",
                          sourceConversationID: UUID(),
                          sourceMessageID: UUID(),
                          createdAt: .now, lastRelevantAt: nil,
                          approved: true, disabled: false,
                          extractionMethod: .structured)
        }
        let package = makePackage(episodes: episodes)
        let prompt = service.build(from: package)

        // PromptAssemblyService caps episodes at prefix(3) → 0-2 included.
        XCTAssertTrue(prompt.systemPrompt.contains("Episode 2"))
        XCTAssertFalse(prompt.systemPrompt.contains("Episode 3"))
    }

    // MARK: - Message assembly

    func testUserInputAppendedAsLastMessage() {
        let package = makePackage(userInput: "Tell me about my project")
        let prompt = service.build(from: package)

        XCTAssertEqual(prompt.messages.last?.role, .user)
        XCTAssertEqual(prompt.messages.last?.content, "Tell me about my project")
    }

    func testSystemMessagesFilteredFromHistory() {
        var package = makePackage()
        package.recentMessages = [
            Message(id: UUID(), conversationID: UUID(),
                    role: .system, content: "System setup",
                    createdAt: .now, status: .complete, tokenCount: nil),
            Message(id: UUID(), conversationID: UUID(),
                    role: .user, content: "Hi",
                    createdAt: .now, status: .complete, tokenCount: nil)
        ]
        let prompt = service.build(from: package)

        // system message excluded, user message + current input = 2
        XCTAssertEqual(prompt.messages.count, 2)
        XCTAssertEqual(prompt.messages[0].content, "Hi")
    }

    // MARK: - Conversation recall layer (L0.6)

    /// When `conversationRecall` is non-empty, the assembled system
    /// prompt must contain a dedicated block introducing the snippets.
    /// We assert both the block header (so a future copy edit doesn't
    /// silently delete the explanation) and the verbatim snippet text
    /// (so the model can quote it back when asked).
    func testRecallBlockRenderedWhenPresent() {
        var package = makePackage(userInput: "What was the API shape we agreed on?")
        package.conversationRecall = [
            "[Uživatel] We agreed on userId: UUID for the API",
            "[Asistent] Confirmed — userId: UUID, createdAt: Date"
        ]

        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("Relevant earlier turns"),
                      "Recall block header missing — copy edit may have stripped it")
        XCTAssertTrue(prompt.systemPrompt.contains("userId: UUID for the API"),
                      "Verbatim recall content missing from system prompt")
        XCTAssertTrue(prompt.systemPrompt.contains("Confirmed — userId: UUID"))
    }

    /// Empty recall must not produce a stray header. Locks down the
    /// guard that prevents "Relevant earlier turns:" with no content
    /// appearing in the prompt — the model would treat the bare
    /// header as an instruction and fabricate snippets.
    func testRecallBlockOmittedWhenEmpty() {
        let package = makePackage()
        let prompt = service.build(from: package)

        XCTAssertFalse(prompt.systemPrompt.contains("Relevant earlier turns"),
                       "Recall block leaked into prompt without content")
    }

    /// Summary + recall coexist: the summary lives at L0.5, recall at
    /// L0.6, and both precede the L1 facts block. The order matters
    /// for narrative coherence — model reads gist → quotes → curated
    /// facts → live history.
    func testSummaryAndRecallOrdering() {
        var package = makePackage()
        package.conversationSummary = "Earlier we discussed user authentication design"
        package.conversationRecall = ["[Uživatel] verbatim recall snippet"]

        let prompt = service.build(from: package)

        guard let summaryRange = prompt.systemPrompt.range(of: "Earlier in this conversation (condensed"),
              let recallRange = prompt.systemPrompt.range(of: "Relevant earlier turns") else {
            return XCTFail("Both blocks must appear in the system prompt")
        }
        XCTAssertLessThan(summaryRange.lowerBound, recallRange.lowerBound,
                          "Summary (gist) must precede recall (verbatim quotes)")
    }
}
