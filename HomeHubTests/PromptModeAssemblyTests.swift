import XCTest
@testable import HomeHub

/// Tests that `PromptAssemblyService` produces the right prompt shape
/// for each `PromptMode`.
///
/// ## What these tests guard
/// 1. `.chat` includes all 7 layers (persona, profile, facts, episodes,
///    file excerpts, skills, privacy guardrail).
/// 2. `.toolFollowup` includes persona + profile + facts + episodes +
///    short tool reminder but NOT full skill instructions.
/// 3. `.summarization` uses the dedicated summarizer prompt and skips
///    all personalisation layers.
/// 4. `.memoryExtraction` uses the JSON schema prompt and skips all
///    personalisation layers.
/// 5. History is trimmed for chat/toolFollowup but empty for
///    summarization/extraction.
/// 6. `PromptBudgetReport.mode` reflects the mode used.
/// 7. `PromptMode.defaultParameters` returns appropriate per-mode values.
@MainActor
final class PromptModeAssemblyTests: XCTestCase {

    private let service = PromptAssemblyService()

    // MARK: - Chat mode

    func testChatModeIncludesAllLayers() {
        let package = makePackage(mode: .chat, withFacts: true, withSkills: true)
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("About the user"))
        XCTAssertTrue(prompt.systemPrompt.contains("Remembered facts"))
        XCTAssertTrue(prompt.systemPrompt.contains("native tools"))
        XCTAssertTrue(prompt.systemPrompt.contains("Never fabricate"))
    }

    func testChatModeTrimsHistory() {
        let messages = makeMessages(count: 30, charLength: 400)
        var package = makePackage(mode: .chat)
        package.recentMessages = messages

        let prompt = service.build(from: package)
        // 30 msgs × ~107 tokens each > budget 1400 → must trim
        XCTAssertLessThan(prompt.messages.count, 31, // 30 history + 1 user input
            "Chat mode should trim history when over budget")
        XCTAssertGreaterThan(prompt.messages.count, 1,
            "Chat mode should keep at least some history + user input")
    }

    func testChatBudgetReportHasChatMode() {
        let package = makePackage(mode: .chat)
        _ = service.build(from: package)
        XCTAssertEqual(service.lastReport?.mode, .chat)
    }

    // MARK: - Tool followup mode

    func testToolFollowupIncludesPersonaAndProfile() {
        let package = makePackage(mode: .toolFollowup)
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("About the user"))
        XCTAssertTrue(prompt.systemPrompt.contains("Never fabricate"))
    }

    func testToolFollowupHasShortToolReminder() {
        let package = makePackage(mode: .toolFollowup, withSkills: true)
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("received an <Observation>"),
            "Tool followup should include the short observation reminder")
        XCTAssertFalse(prompt.systemPrompt.contains("native tools"),
            "Tool followup should NOT include full skill instructions")
    }

    func testToolFollowupIncludesFactsAndEpisodes() {
        let package = makePackage(mode: .toolFollowup, withFacts: true)
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("Remembered facts"))
        XCTAssertTrue(prompt.systemPrompt.contains("Recent context"))
    }

    func testToolFollowupBudgetReport() {
        let package = makePackage(mode: .toolFollowup)
        _ = service.build(from: package)
        XCTAssertEqual(service.lastReport?.mode, .toolFollowup)
    }

    // MARK: - Summarization mode

    func testSummarizationUsesOneShotPrompt() {
        let package = makePackage(mode: .summarization)
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("conversation summarizer"))
        XCTAssertTrue(prompt.systemPrompt.contains("under 120 words"))
    }

    func testSummarizationOmitsPersonalisationLayers() {
        let package = makePackage(mode: .summarization, withFacts: true, withSkills: true)
        let prompt = service.build(from: package)

        XCTAssertFalse(prompt.systemPrompt.contains("About the user"))
        XCTAssertFalse(prompt.systemPrompt.contains("Remembered facts"))
        XCTAssertFalse(prompt.systemPrompt.contains("native tools"))
        XCTAssertFalse(prompt.systemPrompt.contains("Never fabricate"))
    }

    func testSummarizationSkipsHistory() {
        var package = makePackage(mode: .summarization)
        package.recentMessages = makeMessages(count: 10, charLength: 100)

        let prompt = service.build(from: package)
        // Only the user input message, no history
        XCTAssertEqual(prompt.messages.count, 1)
        XCTAssertEqual(service.lastReport?.historyMessagesKept, 0)
        XCTAssertEqual(service.lastReport?.historyMessagesDropped, 0)
    }

    func testSummarizationBudgetReport() {
        let package = makePackage(mode: .summarization)
        _ = service.build(from: package)
        XCTAssertEqual(service.lastReport?.mode, .summarization)
    }

    // MARK: - Memory extraction mode

    func testMemoryExtractionUsesJSONPrompt() {
        let package = makePackage(mode: .memoryExtraction)
        let prompt = service.build(from: package)

        XCTAssertTrue(prompt.systemPrompt.contains("memory extraction system"))
        XCTAssertTrue(prompt.systemPrompt.contains("Required JSON format"))
    }

    func testMemoryExtractionOmitsPersonalisationLayers() {
        let package = makePackage(mode: .memoryExtraction, withFacts: true, withSkills: true)
        let prompt = service.build(from: package)

        XCTAssertFalse(prompt.systemPrompt.contains("About the user"))
        XCTAssertFalse(prompt.systemPrompt.contains("Remembered facts"))
        XCTAssertFalse(prompt.systemPrompt.contains("native tools"))
    }

    func testMemoryExtractionSkipsHistory() {
        var package = makePackage(mode: .memoryExtraction)
        package.recentMessages = makeMessages(count: 10, charLength: 100)

        let prompt = service.build(from: package)
        XCTAssertEqual(prompt.messages.count, 1)
        XCTAssertEqual(service.lastReport?.historyMessagesKept, 0)
    }

    func testMemoryExtractionBudgetReport() {
        let package = makePackage(mode: .memoryExtraction)
        _ = service.build(from: package)
        XCTAssertEqual(service.lastReport?.mode, .memoryExtraction)
    }

    // MARK: - PromptMode.defaultParameters

    func testChatParametersMatchSettings() {
        let settings = AppSettings.default
        let params = PromptMode.chat.defaultParameters(settings: settings)
        XCTAssertEqual(params.maxTokens, settings.maxResponseTokens)
        XCTAssertEqual(params.temperature, settings.temperature)
    }

    func testToolFollowupParametersMatchSettings() {
        let settings = AppSettings.default
        let params = PromptMode.toolFollowup.defaultParameters(settings: settings)
        XCTAssertEqual(params.maxTokens, settings.maxResponseTokens)
    }

    func testSummarizationParametersAreTight() {
        let params = PromptMode.summarization.defaultParameters(settings: .default)
        XCTAssertEqual(params.maxTokens, 200)
        XCTAssertEqual(params.temperature, 0.2)
    }

    func testMemoryExtractionParametersAreDeterministic() {
        let params = PromptMode.memoryExtraction.defaultParameters(settings: .default)
        XCTAssertEqual(params.maxTokens, 384)
        XCTAssertEqual(params.temperature, 0.1)
        XCTAssertTrue(params.stopSequences.isEmpty)
    }

    // MARK: - All modes include user input as last message

    func testAllModesAppendUserInputAsLastMessage() {
        for mode in PromptMode.allCases {
            let package = makePackage(mode: mode, userInput: "Test input for \(mode.rawValue)")
            let prompt = service.build(from: package)
            XCTAssertEqual(prompt.messages.last?.role, .user)
            XCTAssertEqual(prompt.messages.last?.content, "Test input for \(mode.rawValue)",
                "\(mode.rawValue) must append user input as the last message")
        }
    }

    // MARK: - Helpers

    private func makePackage(
        mode: PromptMode,
        withFacts: Bool = false,
        withSkills: Bool = false,
        userInput: String = "Hello"
    ) -> PromptContextPackage {
        let facts: [MemoryFact] = withFacts ? [
            MemoryFact(id: UUID(), content: "Prefers dark mode",
                       category: .preferences, source: .userManual,
                       confidence: 0.9, createdAt: .now, lastUsedAt: nil,
                       pinned: false, disabled: false)
        ] : []

        let episodes: [MemoryEpisode] = withFacts ? [
            MemoryEpisode(id: UUID(),
                          summary: "Working on SwiftUI migration",
                          sourceConversationID: UUID(),
                          sourceMessageID: UUID(),
                          createdAt: .now, lastRelevantAt: nil,
                          approved: true, disabled: false,
                          extractionMethod: .structured)
        ] : []

        return PromptContextPackage(
            assistant: AssistantProfile.defaultAssistant,
            user: UserProfile(
                id: UUID(), displayName: "Tester",
                pronouns: "they/them", occupation: "Engineer",
                locale: "en_US", interests: ["Swift"],
                workingContext: nil,
                preferredResponseStyle: .balanced,
                createdAt: .now, updatedAt: .now
            ),
            facts: facts,
            episodes: episodes,
            recentMessages: [],
            userInput: userInput,
            settings: .default,
            skillInstructions: withSkills ? "You have access to the following native tools/skills:\n- Calculator: basic math" : nil,
            modelCapabilityProfile: .llama,
            promptMode: mode
        )
    }

    private func makeMessages(count: Int, charLength: Int) -> [Message] {
        let convID = UUID()
        return (0..<count).map { i in
            Message(
                id: UUID(),
                conversationID: convID,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: String(repeating: "x", count: charLength),
                createdAt: Date(timeIntervalSinceNow: Double(i)),
                status: .complete,
                tokenCount: nil
            )
        }
    }
}
