import AppIntents
import SwiftUI

@available(iOS 16.0, *)
struct AskAssistantIntent: AppIntent {
    static var title: LocalizedStringResource = "Zeptat se asistenta"
    static var description = IntentDescription("Položí otázku lokálnímu LLM asistentovi a vrátí odpověď.")
    
    @Parameter(title: "Zpráva", description: "Zpráva nebo úkol pro asistenta")
    var message: String
    
    // We run on the main actor to easily interface with the shared AppContainer
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let container = AppContainer.shared
        
        // Ensure services are loaded if running in background
        if container.appState.phase == .launching {
            await container.bootstrap()
        }
        
        let conversationService = container.conversationService
        
        // Create a temporary conversation for the intent, or find the last active
        // For simplicity, we just create a new one to avoid stream collisions in the app
        let tempConversation = await conversationService.createConversation(title: "Siri Dotaz")
        
        // Send the input and await completion natively (no polling)
        await conversationService.sendAndWait(userInput: message, in: tempConversation.id)
        
        // Fetch the final generated message
        let messages = conversationService.messages(in: tempConversation.id)
        guard let lastAssistantMessage = messages.last(where: { $0.role == .assistant }),
              !lastAssistantMessage.content.isEmpty else {
            return .result(value: "Promiň, asistent nedokázal vygenerovat odpověď.")
        }
        
        return .result(value: lastAssistantMessage.content)
    }
}

