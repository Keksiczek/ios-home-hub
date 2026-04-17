import Foundation

/// Builds the prompt and parameters used by the structured memory
/// extraction pass. Uses `PromptAssemblyService` in `.memoryExtraction`
/// mode so the extraction system prompt is centrally managed alongside
/// the chat and summarisation prompts.
///
/// Deterministic temperature, tight token budget, strict JSON-only
/// instruction.
enum ExtractionPromptBuilder {

    /// Builds a `RuntimePrompt` for extracting memory items from `message`.
    ///
    /// Internally creates a minimal `PromptContextPackage` in
    /// `.memoryExtraction` mode. The assembly service strips all
    /// conversational layers (persona, facts, episodes, skills) and
    /// uses the dedicated extraction system prompt.
    @MainActor
    static func buildPrompt(for message: Message, using assembler: PromptAssemblyService? = nil) -> RuntimePrompt {
        let service = assembler ?? PromptAssemblyService()
        let package = PromptContextPackage(
            assistant: .defaultAssistant,
            user: .blank,
            facts: [],
            episodes: [],
            recentMessages: [],
            userInput: userPrompt(for: message.content),
            settings: .default,
            promptMode: .memoryExtraction
        )
        return service.build(from: package)
    }

    /// Mode-specific parameters for extraction.
    static var extractionParameters: RuntimeParameters {
        PromptMode.memoryExtraction.defaultParameters(settings: .default)
    }

    // MARK: - Prompt text

    private static func userPrompt(for content: String) -> String {
        "Extract memory items from this message:\n\n\(content)"
    }
}
