import Foundation

/// Proposes `MemoryCandidate`s from a finished user message.
///
/// v2: tries a structured extraction pass using the local runtime
/// first. If the runtime is unavailable, the model isn't loaded,
/// or the JSON output is invalid, falls back to the original v1
/// heuristic keyword triggers. Chat is never blocked by extraction.
actor MemoryExtractionService {

    private let runtime: (any LocalLLMRuntime)?

    /// - Parameter runtime: The local LLM runtime used for structured
    ///   extraction. Pass `nil` for previews/tests or when only
    ///   heuristic extraction is desired.
    init(runtime: (any LocalLLMRuntime)? = nil) {
        self.runtime = runtime
    }

    /// Main entry point. Tries structured → heuristic fallback.
    func extract(from message: Message) async -> [MemoryCandidate] {
        guard message.role == .user else { return [] }

        // Try structured extraction when the runtime has a model loaded.
        if let runtime, runtime.loadedModel != nil {
            do {
                let candidates = try await extractStructured(
                    from: message, using: runtime
                )
                if !candidates.isEmpty { return candidates }
            } catch {
                // Structured extraction failed — fall through to heuristic.
            }
        }

        return extractHeuristic(from: message)
    }

    // MARK: - Structured extraction

    private func extractStructured(
        from message: Message,
        using runtime: any LocalLLMRuntime
    ) async throws -> [MemoryCandidate] {
        let prompt = ExtractionPromptBuilder.buildPrompt(for: message)
        let parameters = ExtractionPromptBuilder.extractionParameters

        var fullResponse = ""
        let stream = runtime.generate(prompt: prompt, parameters: parameters)
        for try await event in stream {
            switch event {
            case .token(let piece):
                fullResponse += piece
            case .finished:
                break
            }
        }

        guard !fullResponse.isEmpty else {
            throw ExtractionError.emptyResponse
        }

        let jsonString = Self.extractJSON(from: fullResponse)
        guard let data = jsonString.data(using: .utf8) else {
            throw ExtractionError.invalidJSON
        }

        let payload = try JSONDecoder().decode(ExtractionPayload.self, from: data)
        return payload.toCandidates(
            sourceConversationID: message.conversationID,
            sourceMessageID: message.id
        )
    }

    /// Attempts to extract a JSON object from model output that may
    /// include markdown fencing or surrounding prose.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if present.
        if let fenceStart = trimmed.range(of: "```json"),
           let fenceEnd = trimmed.range(of: "```", range: fenceStart.upperBound..<trimmed.endIndex) {
            let inner = trimmed[fenceStart.upperBound..<fenceEnd.lowerBound]
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let fenceStart = trimmed.range(of: "```"),
           let fenceEnd = trimmed.range(of: "```", range: fenceStart.upperBound..<trimmed.endIndex) {
            let inner = trimmed[fenceStart.upperBound..<fenceEnd.lowerBound]
            let innerTrimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if innerTrimmed.hasPrefix("{") { return innerTrimmed }
        }

        // Find outermost braces.
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }

        return trimmed
    }

    // MARK: - Heuristic extraction (v1 fallback)

    private struct Trigger {
        let phrase: String
        let category: MemoryFact.Category
    }

    private let triggers: [Trigger] = [
        Trigger(phrase: "my name is",       category: .personal),
        Trigger(phrase: "i live in",        category: .personal),
        Trigger(phrase: "i'm from",         category: .personal),
        Trigger(phrase: "i work at",        category: .work),
        Trigger(phrase: "i work as",        category: .work),
        Trigger(phrase: "my job is",        category: .work),
        Trigger(phrase: "i'm working on",   category: .projects),
        Trigger(phrase: "i'm building",     category: .projects),
        Trigger(phrase: "my project",       category: .projects),
        Trigger(phrase: "i prefer",         category: .preferences),
        Trigger(phrase: "i like",           category: .preferences),
        Trigger(phrase: "i don't like",     category: .preferences),
        Trigger(phrase: "i hate",           category: .preferences),
        Trigger(phrase: "remember that",    category: .other),
        Trigger(phrase: "please remember",  category: .other)
    ]

    private func extractHeuristic(from message: Message) -> [MemoryCandidate] {
        let lowered = message.content.lowercased()
        var seen = Set<String>()
        var results: [MemoryCandidate] = []

        for trigger in triggers where lowered.contains(trigger.phrase) {
            let cleaned = message.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = String(cleaned.prefix(160))
            guard seen.insert(trigger.category.rawValue).inserted else { continue }
            results.append(MemoryCandidate(
                id: UUID(),
                content: snippet,
                kind: .fact,
                category: trigger.category,
                sourceConversationID: message.conversationID,
                sourceMessageID: message.id,
                proposedAt: .now,
                extractionMethod: .heuristic
            ))
        }

        return results
    }
}

enum ExtractionError: Error {
    case invalidJSON
    case emptyResponse
}
