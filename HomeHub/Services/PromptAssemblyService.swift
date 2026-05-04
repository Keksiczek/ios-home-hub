import Foundation

/// Turns a `PromptContextPackage` into the `RuntimePrompt` the runtime
/// actually sees. Mode-aware: the `promptMode` field on the package
/// selects which system-prompt layers to include and how to shape
/// the message window.
///
/// ## Prompt modes
///
/// | Mode              | System prompt layers      | History | Notes              |
/// |-------------------|---------------------------|---------|--------------------|
/// | `.chat`           | L0–L4 + privacy rail      | trimmed | Full conversational|
/// | `.toolFollowup`   | L0–L2 + short tool remind | trimmed | Post-action loop   |
/// | `.summarization`  | Dedicated one-shot         | none    | T=0.2, 200 tokens  |
/// | `.memoryExtraction`| Dedicated JSON schema     | none    | T=0.1, 384 tokens  |
///
/// ## Layered memory assembly (`.chat` mode)
///
/// L0: Assistant persona + tone + style + user profile
/// L1: Approved durable facts (pinned + keyword-scored)
/// L2: Relevant episodic summaries
/// L3: Source excerpts from attached files
/// L4: Agentic tool instructions
///
/// Privacy guardrails + recent conversation messages + current input
/// follow the memory layers.
///
/// ## Observability
/// The service is intentionally a plain `final class` rather than an
/// `ObservableObject`. The only piece of state SwiftUI cares about —
/// the most recent prompt budget report — lives on a separate
/// `PromptBudgetReporter` so the assembly pipeline can stay free of
/// publisher overhead and so previews/tests can construct a service
/// without wiring an observable.
@MainActor
final class PromptAssemblyService {

    /// Optional sink for the budget report emitted on every `build(from:)`.
    /// In production this is the shared `PromptBudgetReporter` exposed by
    /// `AppContainer`; tests/previews/previews can leave it `nil`.
    private let reporter: PromptBudgetReporter?

    init(reporter: PromptBudgetReporter? = nil) {
        self.reporter = reporter
    }

    func build(from package: PromptContextPackage) -> RuntimePrompt {
        let mode = package.promptMode
        let system = assembleSystemPrompt(for: mode, from: package)

        let profile = package.modelCapabilityProfile ?? .default
        let budgeter = PromptTokenBudgeter(profile: profile)

        // Summarisation and extraction are single-turn — no history to trim.
        let trimResult: (kept: [Message], dropped: Int)
        switch mode {
        case .summarization, .memoryExtraction:
            trimResult = ([], 0)
        case .chat, .toolFollowup:
            trimResult = budgeter.trimHistory(package.recentMessages)
        }

        var runtimeMessages: [RuntimeMessage] = trimResult.kept.compactMap { m in
            switch m.role {
            case .user:      return RuntimeMessage(role: .user, content: m.content)
            case .assistant: return RuntimeMessage(role: .assistant, content: m.content)
            case .system:    return nil
            }
        }

        runtimeMessages.append(RuntimeMessage(role: .user, content: package.userInput))

        let historyTokens = trimResult.kept.reduce(0) {
            $0 + budgeter.tokensForMessage(content: $1.content)
        }
        let report = PromptBudgetReport(
            family: profile.family,
            mode: mode,
            sections: [
                .init(name: "system",     tokens: budgeter.tokens(in: system)),
                .init(name: "history",    tokens: historyTokens),
                .init(name: "user_input", tokens: budgeter.tokensForMessage(content: package.userInput))
            ],
            historyMessagesKept: trimResult.kept.count,
            historyMessagesDropped: trimResult.dropped,
            generationReserveTokens: profile.generationReserveTokens
        )
        reporter?.publish(report)

        return RuntimePrompt(systemPrompt: system, messages: runtimeMessages)
    }

    // MARK: - Mode dispatch

    private func assembleSystemPrompt(
        for mode: PromptMode,
        from package: PromptContextPackage
    ) -> String {
        switch mode {
        case .chat:              return assembleChatPrompt(from: package)
        case .toolFollowup:      return assembleToolFollowupPrompt(from: package)
        case .summarization:     return assembleSummarizationPrompt()
        case .memoryExtraction:  return assembleMemoryExtractionPrompt()
        }
    }

    // MARK: - Chat (full 7-layer assembly)

    private func assembleChatPrompt(from package: PromptContextPackage) -> String {
        var chunks: [String] = []

        // L0a. Assistant persona base
        chunks.append(package.assistant.systemPromptBase)

        // L0a'. Hard rules (if enabled). Placed RIGHT after the persona so they sit at the
        // top of the context where small models pay attention. These are the
        // instructions that tackle the "weird characters / hallucinations /
        // bad formatting" issues most directly:
        //   1. Plain Markdown only — no chat-template tokens.
        //   2. Don't invent facts; admit uncertainty.
        //   3. One coherent answer, no echo of the user's question.
        //   4. Stop after answering — don't keep talking to yourself.
        if package.settings.guardrailsConfig.hardRulesEnabled {
            chunks.append("""
            Hard rules (follow ALL of them):
            1. Output plain Markdown only. NEVER emit chat-template control \
            tokens (e.g. <|im_start|>, <|eot_id|>, <start_of_turn>, [INST], </s>) \
            or role headers like "assistant:" / "user:". Those are wire-format \
            only and must never appear in your visible reply.
            2. If you don't know something, say so plainly. Do NOT invent names, \
            dates, prices, URLs, or quotes. When uncertain, ask a clarifying \
            question or state the limit of your knowledge.
            3. Match the user's language. If they wrote in Czech, answer in Czech \
            with correct diacritics; if they wrote in English, answer in English. \
            Never mix scripts inside a single reply unless quoting.
            4. Write ONE coherent answer. Do not repeat the user's question, do \
            not roleplay both sides of the conversation, do not continue with a \
            new "User:" turn after your reply.
            5. Use Markdown sparingly: short paragraphs, lists only when they \
            help, fenced code blocks for code. Never wrap a one-line answer in \
            a list or heading.
            """)
        }

        // L0b. Tone + style hints
        chunks.append("""
        Tone: \(package.assistant.tone.label.lowercased()). \
        Preferred response style: \(package.user.preferredResponseStyle.label.lowercased()) — \
        \(package.user.preferredResponseStyle.blurb)
        """)

        // L0bʹ. Context rail — date/time, location, language policy,
        // tool policy (math is mandatory, web is tool-only), style.
        // Single source of truth for all per-turn context constraints;
        // lives in PromptBuilder so it can be unit-tested in isolation.
        chunks.append(PromptBuilder.contextRail(
            .live(
                settings: package.settings,
                availableTools: package.availableTools
            )
        ))

        // L0c. User profile (from onboarding — name, pronouns, interests…).
        appendUserProfile(from: package, to: &chunks)

        // L0d. User memory — user-curated notes + preferences from the
        // UserDefaults-backed `UserMemoryStore`. Injected verbatim so
        // small models see the user's own hand-written facts on every
        // turn regardless of retrieval ranking.
        if let block = package.userMemoryBlock, !block.isEmpty {
            chunks.append(block)
        }

        // L0.5: Summary of older messages
        if let summary = package.conversationSummary {
            chunks.append("""
            Earlier in this conversation (condensed summary — may be incomplete):
            \(summary)
            """)
        }

        // L1. Durable facts
        if package.settings.guardrailsConfig.factsEnabled {
            appendFacts(from: package, to: &chunks)
        }

        // L2. Episodic summaries
        if package.settings.guardrailsConfig.episodesEnabled {
            appendEpisodes(from: package, to: &chunks)
        }

        // L3. Source excerpts
        if package.settings.guardrailsConfig.fileExcerptsEnabled {
            appendFileExcerpts(from: package, to: &chunks)
        }

        // L4. Agentic tool instructions
        if package.settings.guardrailsConfig.skillInstructionsEnabled,
           let skills = package.skillInstructions, !skills.isEmpty {
            chunks.append(skills)
        }

        // Privacy guardrail — conditional: only claim "no network access"
        // when the web-search tool isn't available. Otherwise the rail
        // would contradict the tool policy above. Also respects guardrails config.
        if package.settings.guardrailsConfig.privacyGuardrailEnabled {
            chunks.append(privacyGuardrail(for: package))
        }

        return chunks.joined(separator: "\n\n")
    }

    // MARK: - Tool followup (post-action loop iteration)

    private func assembleToolFollowupPrompt(from package: PromptContextPackage) -> String {
        var chunks: [String] = []

        // L0a. Persona (same as chat — the model should stay in character)
        chunks.append(package.assistant.systemPromptBase)

        // L0b. Tone
        chunks.append("""
        Tone: \(package.assistant.tone.label.lowercased()). \
        Preferred response style: \(package.user.preferredResponseStyle.label.lowercased()) — \
        \(package.user.preferredResponseStyle.blurb)
        """)

        // Context rail — keep date, language, style consistent across the
        // tool-followup turn so the assistant doesn't "forget" that it
        // should answer in Czech mid-loop.
        chunks.append(PromptBuilder.contextRail(
            .live(
                settings: package.settings,
                availableTools: package.availableTools
            )
        ))

        // L0c. User profile (helpful for personalised follow-up)
        appendUserProfile(from: package, to: &chunks)

        // L1. Durable facts (lightweight context)
        appendFacts(from: package, to: &chunks)

        // L2. Episodes
        appendEpisodes(from: package, to: &chunks)

        // Short tool reminder instead of full L4 instructions
        chunks.append("""
        You just used a tool and received an <Observation> with the result. \
        Use that information to formulate a helpful, natural response to the user. \
        Do NOT output another <tool_call> block unless absolutely necessary.
        """)

        if package.settings.guardrailsConfig.privacyGuardrailEnabled {
            chunks.append(privacyGuardrail(for: package))
        }

        return chunks.joined(separator: "\n\n")
    }

    // MARK: - Summarization (single-turn, dedicated prompt)

    private func assembleSummarizationPrompt() -> String {
        """
        You are a conversation summarizer. Produce a concise factual summary \
        of the conversation below. Be neutral, factual, and under 120 words. \
        Focus on key topics, decisions, and conclusions. Output only the summary \
        text — no preamble, no labels.
        """
    }

    // MARK: - Memory extraction (single-turn, JSON schema)

    private func assembleMemoryExtractionPrompt() -> String {
        """
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
    }

    // MARK: - Shared layer helpers

    private func appendUserProfile(from package: PromptContextPackage, to chunks: inout [String]) {
        var userLines: [String] = []
        if !package.user.displayName.isEmpty {
            userLines.append("Name: \(package.user.displayName)")
        }
        if let pronouns = package.user.pronouns, !pronouns.isEmpty {
            userLines.append("Pronouns: \(pronouns)")
        }
        if let occupation = package.user.occupation, !occupation.isEmpty {
            userLines.append("Work: \(occupation)")
        }
        if !package.user.interests.isEmpty {
            userLines.append("Interests: \(package.user.interests.joined(separator: ", "))")
        }
        if let ctx = package.user.workingContext, !ctx.isEmpty {
            userLines.append("Current context: \(ctx)")
        }
        if !userLines.isEmpty {
            chunks.append("About the user:\n" + userLines.joined(separator: "\n"))
        }
    }

    private func appendFacts(from package: PromptContextPackage, to chunks: inout [String]) {
        guard !package.facts.isEmpty else { return }
        let factLines = package.facts.prefix(8).map { "- \($0.content)" }
        chunks.append("""
        Remembered facts (user-controlled, may be incomplete):
        \(factLines.joined(separator: "\n"))
        """)
    }

    private func appendEpisodes(from package: PromptContextPackage, to chunks: inout [String]) {
        guard !package.episodes.isEmpty else { return }
        let episodeLines = package.episodes.prefix(3).map { "- \($0.summary)" }
        chunks.append("""
        Recent context (episodic, may be outdated):
        \(episodeLines.joined(separator: "\n"))
        """)
    }

    private func appendFileExcerpts(from package: PromptContextPackage, to chunks: inout [String]) {
        guard !package.fileExcerpts.isEmpty else { return }
        let fileLines = package.fileExcerpts.map { "--- FILE EXCERPT ---\n\($0)\n--- END EXCERPT ---" }
        chunks.append("""
        The user attached the following file contents to their message. Use this provided information to answer their prompt, but do not fabricate information if the answer is not in the text:
        \(fileLines.joined(separator: "\n\n"))
        """)
    }

    /// Privacy rail. Wording flips depending on whether a web-search tool
    /// is actually registered — claiming "no network access" while the
    /// WebSearch tool is advertised (L4) trains the model on contradictory
    /// signals and makes tool calls flaky.
    private func privacyGuardrail(for package: PromptContextPackage) -> String {
        let hasWebSearch = package.availableTools
            .map { $0.lowercased() }
            .contains("websearch")

        if hasWebSearch {
            return """
            Never fabricate personal details about the user. If you're \
            unsure, ask or say you don't know. You may reach the network \
            ONLY via the WebSearch tool — never pretend to have browsed \
            on your own, and never send personal data through the tool.
            """
        } else {
            return """
            Never fabricate personal details about the user. If you're \
            unsure, ask or say you don't know. You run entirely on-device \
            with no network access — don't pretend to look anything up.
            """
        }
    }
}
