import Foundation

/// Proposes `MemoryCandidate`s from a finished user message.
///
/// ## Three-layer extraction pipeline
///
/// Extraction runs cheapest-first. Expensive layers are skipped when
/// cheaper ones already found candidates — saving battery and latency.
///
/// | Layer | Method           | Cost          | When it runs               |
/// |-------|------------------|---------------|----------------------------|
/// | 1     | Keyword triggers | microseconds  | always                     |
/// | 2     | NLTagger entities| milliseconds  | always (additive)          |
/// | 3     | Local LLM JSON   | seconds       | only if layers 1+2 empty   |
///
/// Layer 2 candidates are de-duplicated against Layer 1 by category so
/// the same fact isn't proposed twice.
///
/// Layer 3 only fires when:
/// - Layers 1 + 2 found zero candidates, AND
/// - The message is at least `llmMinMessageLength` characters (short
///   messages like "hi" or "thanks" aren't worth inference), AND
/// - A model is currently loaded in the runtime.
actor MemoryExtractionService {

    /// `RuntimeManager` rather than a raw `LocalLLMRuntime` so the service
    /// observes the same load/unload state as the rest of the app: when
    /// the user-driven manager unloads a model under memory pressure,
    /// `activeModel` flips to `nil` and Layer 3 stops firing. Holding a
    /// raw runtime would have hidden that transition until the runtime's
    /// own `loadedModel` mirror caught up.
    private let runtime: RuntimeManager?

    /// Messages shorter than this skip the LLM extraction layer even
    /// when the cheaper layers found nothing.
    static let llmMinMessageLength = 40

    /// - Parameter runtime: The runtime manager used for structured
    ///   extraction. Pass `nil` for previews/tests or when only
    ///   heuristic + NL extraction is desired.
    init(runtime: RuntimeManager? = nil) {
        self.runtime = runtime
    }

    /// Main entry point — runs the 3-layer extraction pipeline.
    func extract(from message: Message) async -> [MemoryCandidate] {
        guard message.role == .user else { return [] }

        // Layer 1: Keyword triggers (microseconds).
        var candidates = extractHeuristic(from: message)
        let coveredCategories = Set(candidates.map(\.category))

        // Layer 2: NLTagger named entities (milliseconds).
        // Skip categories already covered by Layer 1 to avoid duplicates.
        let nlCandidates = NLExtractionPass.extract(from: message)
        for c in nlCandidates where !coveredCategories.contains(c.category) {
            candidates.append(c)
        }

        // Layer 3: Structured LLM extraction (seconds).
        // Only when the cheap layers found nothing and the message is
        // long enough to plausibly contain extractable information.
        if candidates.isEmpty
            && message.content.count >= Self.llmMinMessageLength,
           let runtime,
           await runtime.activeModel != nil
        {
            do {
                let llmCandidates = try await extractStructured(
                    from: message, using: runtime
                )
                candidates.append(contentsOf: llmCandidates)
            } catch {
                // Structured extraction failed — return empty.
            }
        }

        return candidates
    }

    // MARK: - Structured extraction

    private func extractStructured(
        from message: Message,
        using runtime: RuntimeManager
    ) async throws -> [MemoryCandidate] {
        let prompt = await ExtractionPromptBuilder.buildPrompt(for: message)
        let parameters = ExtractionPromptBuilder.extractionParameters

        var fullResponse = ""
        let stream = await runtime.generate(prompt: prompt, parameters: parameters)
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
