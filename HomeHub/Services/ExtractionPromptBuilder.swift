import Foundation

/// Builds the prompt and parameters used by the structured memory
/// extraction pass. Deterministic temperature, tight token budget,
/// strict JSON-only instruction.
enum ExtractionPromptBuilder {

    static func buildPrompt(for message: Message) -> RuntimePrompt {
        RuntimePrompt(
            systemPrompt: systemPrompt,
            messages: [
                RuntimeMessage(role: .user, content: userPrompt(for: message.content))
            ]
        )
    }

    /// Low-temperature, short-budget parameters for extraction.
    static let extractionParameters = RuntimeParameters(
        maxTokens: 384,
        temperature: 0.1,
        topP: 0.9,
        stopSequences: []
    )

    // MARK: - Prompt text

    private static let systemPrompt = """
    You are a memory extraction system for a personal assistant. \
    Analyze the user message and extract durable information worth \
    remembering for future conversations.

    Extract two kinds of items:

    1. FACTS — stable, long-lived information about the user:
       - Identity (name, location, pronouns)
       - Work (job, employer, role)
       - Projects (what they're building or working on)
       - Preferences (likes, dislikes, communication style)
       - Relationships (people they mention by name and role)

    2. EPISODES — compact summaries of time-bound context:
       - What the user is currently working on or planning
       - Stated goals or deadlines
       - Decisions they've made or are considering
       - Important recent developments

    Rules:
    - Only extract information useful in future conversations.
    - Do NOT extract: fleeting one-off requests, generic small talk, \
    purely transient wording, or information already obvious from \
    the conversation itself.
    - Keep each item concise — one sentence maximum.
    - Assign a confidence between 0.0 and 1.0 for each item.
    - Extract at most 5 items total (facts + episodes combined). \
    Prefer the highest-confidence, most durable items; omit the rest.
    - If nothing is worth extracting, return empty arrays.
    - Return ONLY valid JSON. No prose, no markdown fencing, no \
    explanation outside the JSON object.

    Allowed fact categories: personal, work, preferences, \
    relationships, projects, other

    Required JSON format:
    {"facts":[{"content":"...","category":"...","confidence":0.0}],\
    "episodes":[{"summary":"...","confidence":0.0}]}
    """

    private static func userPrompt(for content: String) -> String {
        "Extract memory items from this message:\n\n\(content)"
    }
}
