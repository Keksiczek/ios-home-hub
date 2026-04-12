import AppIntents

// MARK: - Intents

/// Opens HomeHub and starts a new conversation.
/// Triggered via Siri ("New HomeHub chat") or the Shortcuts app.
struct StartNewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New HomeHub Chat"
    static let description = IntentDescription(
        "Open HomeHub and start a new conversation"
    )
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Signal the app to create a new conversation when it becomes active.
        UserDefaults.standard.set(true, forKey: "homeHub.pendingNewChat")
        return .result()
    }
}

// MARK: - Shortcuts provider

/// Exposes HomeHub's App Shortcuts to Siri and the Shortcuts app.
struct HomeHubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
