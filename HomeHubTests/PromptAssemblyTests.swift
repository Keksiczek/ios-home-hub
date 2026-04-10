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
        let system = prompt.systemPrompt

        // L0: profile appears before L1: facts
        let profileRange = system.range(of: "About the user")!
        let factsRange = system.range(of: "Remembered facts")!
        let episodesRange = system.range(of: "Recent context")!
        let guardrailsRange = system.range(of: "Never fabricate")!

        XCTAssertTrue(profileRange.lowerBound < factsRange.lowerBound)
        XCTAssertTrue(factsRange.lowerBound < episodesRange.lowerBound)
        XCTAssertTrue(episodesRange.lowerBound < guardrailsRange.lowerBound)
    }

    // MARK: - Limits

    func testFactsAreCappedAtTwelve() {
        let facts = (0..<20).map { i in
            MemoryFact(id: UUID(), content: "Fact \(i)",
                       category: .other, source: .userManual,
                       confidence: 1.0, createdAt: .now, lastUsedAt: nil,
                       pinned: false, disabled: false)
        }
        let package = makePackage(facts: facts)
        let prompt = service.build(from: package)

        // Should contain facts 0-11 but not 12+
        XCTAssertTrue(prompt.systemPrompt.contains("Fact 11"))
        XCTAssertFalse(prompt.systemPrompt.contains("Fact 12"))
    }

    func testEpisodesAreCappedAtSix() {
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

        XCTAssertTrue(prompt.systemPrompt.contains("Episode 5"))
        XCTAssertFalse(prompt.systemPrompt.contains("Episode 6"))
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
}
