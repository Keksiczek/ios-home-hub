import Foundation

/// Sample data used by SwiftUI previews.
enum PreviewSamples {
    static let user = UserProfile(
        id: UUID(),
        displayName: "Alex",
        pronouns: "they/them",
        occupation: "Product designer",
        locale: "en_US",
        interests: ["typography", "long walks", "espresso"],
        workingContext: "Launching a meditation app",
        preferredResponseStyle: .balanced,
        createdAt: .now,
        updatedAt: .now
    )

    static let assistant = AssistantProfile.defaultAssistant

    static let conversation = Conversation.new(
        assistantID: assistant.id,
        modelID: "llama-3.2-3b-instruct-q4_k_m",
        title: "Getting started"
    )

    static let messages: [Message] = [
        Message(id: UUID(),
                conversationID: conversation.id,
                role: .user,
                content: "What can you do offline?",
                createdAt: .now.addingTimeInterval(-120),
                status: .complete,
                tokenCount: 12),
        Message(id: UUID(),
                conversationID: conversation.id,
                role: .assistant,
                content: "I run entirely on this device. I can chat, draft, summarize, brainstorm — and remember things you let me remember. Nothing leaves your iPhone.",
                createdAt: .now.addingTimeInterval(-110),
                status: .complete,
                tokenCount: 38)
    ]

    static let facts: [MemoryFact] = [
        MemoryFact(id: UUID(),
                   content: "Prefers concise replies in the morning",
                   category: .preferences,
                   source: .userManual,
                   confidence: 0.95,
                   createdAt: .now,
                   lastUsedAt: nil,
                   pinned: true,
                   disabled: false),
        MemoryFact(id: UUID(),
                   content: "Designs a meditation app called Stillpoint",
                   category: .projects,
                   source: .onboarding,
                   confidence: 1.0,
                   createdAt: .now,
                   lastUsedAt: nil,
                   pinned: false,
                   disabled: false)
    ]
}
