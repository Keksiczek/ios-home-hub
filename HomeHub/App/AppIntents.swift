import AppIntents

// MARK: - Open-app intents

/// Opens HomeHub and starts a new conversation.
/// Triggered via Siri ("New HomeHub chat") or the Shortcuts app.
struct StartNewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New HomeHub Chat"
    static let description = IntentDescription(
        "Open HomeHub and start a new conversation",
        categoryName: "Chat"
    )
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Signal the app to create a new conversation when it becomes active.
        // The `.active` scenePhase handler in `AppContainer` consumes the
        // flag and routes through `ConversationService.createConversation`.
        UserDefaults.standard.set(true, forKey: "homeHub.pendingNewChat")
        return .result()
    }
}

// MARK: - Shortcuts provider

/// Exposes HomeHub's App Shortcuts to Siri and the Shortcuts app.
///
/// Adding a new intent here gives it a top-level Siri phrase set
/// AND a tile in Spotlight's "Shortcuts" suggestion strip. Each
/// `AppShortcut` declaration is a curated promotion of an
/// `AppIntent`; not every intent needs a shortcut entry — leave
/// niche / power-user intents off this list to keep the Shortcuts
/// gallery clean.
struct HomeHubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHomeHubIntent(),
            phrases: [
                // Only static-text or AppEntity/AppEnum interpolation
                // is allowed in App Shortcut phrases — `String`
                // parameters can't be inlined here, Siri will prompt
                // for the question after the phrase activates.
                "Ask \(.applicationName)",
                "Ask the \(.applicationName) assistant"
            ],
            shortTitle: "Ask",
            systemImageName: "brain"
        )

        AppShortcut(
            intent: ContinueLastChatIntent(),
            phrases: [
                "Continue \(.applicationName) chat",
                "Open last \(.applicationName) chat",
                "Resume \(.applicationName)"
            ],
            shortTitle: "Continue Chat",
            systemImageName: "arrow.uturn.backward.circle"
        )

        AppShortcut(
            intent: SummarizeTextIntent(),
            phrases: [
                "Summarise with \(.applicationName)",
                "Summarize with \(.applicationName)",
                "\(.applicationName) summary"
            ],
            shortTitle: "Summarise",
            systemImageName: "text.append"
        )

        AppShortcut(
            intent: SaveToMemoryIntent(),
            phrases: [
                "Save to \(.applicationName) memory",
                "Remember in \(.applicationName)"
            ],
            shortTitle: "Save to Memory",
            systemImageName: "sparkles.rectangle.stack"
        )

        AppShortcut(
            intent: QueryWorkspaceIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Find in \(.applicationName)"
            ],
            shortTitle: "Search Knowledge Base",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: AskOverImportedDocumentIntent(),
            phrases: [
                "Ask \(.applicationName) about \(\.$document)",
                "\(.applicationName) about \(\.$document)"
            ],
            shortTitle: "Ask About Document",
            systemImageName: "doc.text.magnifyingglass"
        )

        AppShortcut(
            intent: StartNewChatIntent(),
            phrases: [
                "Start a new \(.applicationName) chat",
                "New chat in \(.applicationName)",
                "Open \(.applicationName)",
                "Chat with \(.applicationName)"
            ],
            shortTitle: "New Chat",
            systemImageName: "bubble.left.and.bubble.right"
        )

        // Legacy Czech-titled intent. Kept registered so users
        // who wired their Siri phrases against the older title
        // ("Zeptat se asistenta") don't lose them.
        AppShortcut(
            intent: AskAssistantIntent(),
            phrases: [
                "Zeptej se asistenta \(.applicationName)",
                "Pošli zprávu asistentovi \(.applicationName)"
            ],
            shortTitle: "Zeptat se asistenta",
            systemImageName: "brain"
        )
    }
}
