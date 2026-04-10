import Foundation

/// Generates a concise text summary of a list of messages using the
/// local LLM.
///
/// Runs on the main actor so it shares the runtime safely with
/// `ConversationService` without concurrent C++ context access. The
/// service is stateless — the caller owns all storage decisions.
///
/// Typical trigger: called by `ConversationService` when a conversation
/// grows beyond the history window and the context budget is >60% used.
/// The summary is injected into the system prompt for subsequent turns
/// so older context isn't silently lost.
@MainActor
final class SummarizationService {
    private let runtime: RuntimeManager

    init(runtime: RuntimeManager) {
        self.runtime = runtime
    }

    /// Summarises `messages` into a single concise paragraph.
    /// Returns `nil` when the runtime has no model loaded or generation fails.
    func summarize(messages: [Message]) async -> String? {
        guard runtime.activeModel != nil, !messages.isEmpty else { return nil }

        let lines = messages
            .filter { $0.role != .system && !$0.content.isEmpty }
            .map { "[\($0.role == .user ? "User" : "Assistant")] \($0.content)" }

        guard !lines.isEmpty else { return nil }

        let transcript = lines.joined(separator: "\n")

        let prompt = RuntimePrompt(
            systemPrompt: """
            You are a conversation summarizer. Produce a concise factual summary \
            of the conversation below. Be neutral, factual, and under 120 words. \
            Focus on key topics, decisions, and conclusions. Output only the summary \
            text — no preamble, no labels.
            """,
            messages: [
                RuntimeMessage(
                    role: .user,
                    content: "Summarize this conversation:\n\n\(transcript)"
                )
            ]
        )

        let parameters = RuntimeParameters(
            maxTokens: 200,
            temperature: 0.2,
            topP: 0.9,
            stopSequences: stopSequencesForCurrentModel()
        )

        var output = ""
        do {
            let stream = runtime.generate(prompt: prompt, parameters: parameters)
            for try await event in stream {
                switch event {
                case .token(let piece): output += piece
                case .finished:         break
                }
            }
        } catch {
            return nil
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stopSequencesForCurrentModel() -> [String] {
        switch runtime.activeModel?.family.lowercased() {
        case "gemma3", "gemma2": return ["<end_of_turn>"]
        case "llama":            return ["<|eot_id|>"]
        default:                 return []
        }
    }
}
