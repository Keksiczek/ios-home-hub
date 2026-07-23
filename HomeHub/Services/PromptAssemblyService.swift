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
        // Split-aware assembly. Chat mode returns (stable, volatile);
        // other modes are single-shot — no KV-cache reuse possible
        // anyway — so their whole prompt is treated as stable.
        let (stableSystem, volatileSystem): (String, String) = {
            switch mode {
            case .chat:
                return assembleChatPromptSplit(from: package)
            case .toolFollowup, .summarization, .memoryExtraction:
                return (assembleSystemPrompt(for: mode, from: package), "")
            }
        }()
        // (Previously `let system = stable + volatile` was built here
        // and passed into `RuntimePrompt(systemPrompt:)`. Since the
        // runtime now reads `stableSystemPrompt` / `volatileSystemPrompt`
        // separately for cache-aware assembly, the merged string is
        // dead. Removed to silence the warning.)

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

        // Only forward image bytes when the active model family
        // can actually consume them. Pure-text families would just
        // accept the Data and discard it — copying ~500 KB per
        // attachment for nothing.
        let imagesForTurn: [Data]? = (profile.supportsVision && !package.userImages.isEmpty)
            ? package.userImages
            : nil
        runtimeMessages.append(RuntimeMessage(
            role: .user,
            content: package.userInput,
            images: imagesForTurn
        ))

        let historyTokens = trimResult.kept.reduce(0) {
            $0 + budgeter.tokensForMessage(content: $1.content)
        }
        // Use the accurate (NLTokenizer-backed) estimator for the one-shot
        // per-turn counts; the hot streaming path still uses the fast heuristic.
        //
        // Note on summary + recall accounting: their token cost is
        // already inside `system` (both are appended to the assembled
        // system prompt before we measure it). Splitting them out as
        // separate sections would double-count toward
        // `totalPromptTokens`. Diagnostics that need the per-layer
        // breakdown can re-estimate `package.conversationSummary` and
        // `package.conversationRecall` directly; we keep this report
        // additive-correct so callers can trust the total.
        // Split system into "stable" (cacheable across turns) and
        // "volatile" (per-turn churn) for the diagnostic report. The
        // numbers still add up to the same total — we just break out
        // the cacheable fraction so the Diagnostics view can show
        // "62 % of system prompt is reusable across turns" and the
        // user can reason about why some turns feel faster than others.
        let stableTokens = budgeter.tokensAccurate(in: stableSystem)
        let volatileTokens = volatileSystem.isEmpty ? 0 : budgeter.tokensAccurate(in: volatileSystem)
        let report = PromptBudgetReport(
            family: profile.family,
            mode: mode,
            sections: [
                .init(name: "system.stable",   tokens: stableTokens),
                .init(name: "system.volatile", tokens: volatileTokens),
                .init(name: "history",         tokens: historyTokens),
                .init(name: "user_input",      tokens: budgeter.tokensAccurate(in: package.userInput))
            ],
            historyMessagesKept: trimResult.kept.count,
            historyMessagesDropped: trimResult.dropped,
            generationReserveTokens: profile.generationReserveTokens
        )
        reporter?.publish(report)

        let runtimePrompt = RuntimePrompt(
            stableSystemPrompt: stableSystem,
            volatileSystemPrompt: volatileSystem,
            messages: runtimeMessages
        )

        // Diagnostic log: emit a compact snapshot of what's actually
        // going to the runtime. Debug-level so it's off by default in
        // Release but trivial to switch on in Console.app when chasing
        // a quality regression ("did the model see X?" / "is the
        // language block actually present?"). Counts of layers + first
        // / last 120 chars of each section are enough to spot most
        // wiring bugs without firehosing Console with a 2 KB blob per
        // turn.
        Self.logPromptSnapshot(
            mode: mode,
            family: profile.family,
            stable: stableSystem,
            volatile: volatileSystem,
            messageCount: runtimeMessages.count,
            userInput: package.userInput,
            isWeak: package.modelCapabilityProfile?.isWeakInstructionFollower ?? false
        )

        return runtimePrompt
    }

    /// Compact prompt snapshot for `HHLog.runtime` at debug level.
    /// Truncates each chunk to ~120 chars on both ends; the goal is
    /// "is the structure right?", not "show me every token".
    private static func logPromptSnapshot(
        mode: PromptMode,
        family: String,
        stable: String,
        volatile: String,
        messageCount: Int,
        userInput: String,
        isWeak: Bool
    ) {
        func sketch(_ s: String, limit: Int = 120) -> String {
            let trimmed = s.replacingOccurrences(of: "\n", with: " ⏎ ")
            if trimmed.count <= limit * 2 { return trimmed }
            let head = trimmed.prefix(limit)
            let tail = trimmed.suffix(limit)
            return "\(head) … \(tail)"
        }
        HHLog.runtime.debug("""
            Prompt[\(mode.rawValue, privacy: .public)] family=\(family, privacy: .public) weak=\(isWeak, privacy: .public) \
            stable=\(stable.count, privacy: .public)c volatile=\(volatile.count, privacy: .public)c msgs=\(messageCount, privacy: .public) \
            stable=\"\(sketch(stable), privacy: .public)\" \
            volatile=\"\(sketch(volatile), privacy: .public)\" \
            user=\"\(sketch(userInput, limit: 80), privacy: .public)\"
            """)
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

    /// Backwards-compat wrapper. Joins the split assembly into a
    /// single string for callers that don't yet consume the split
    /// form. New code should prefer `assembleChatPromptSplit` so the
    /// stable prefix can be cache-pinned downstream.
    private func assembleChatPrompt(from package: PromptContextPackage) -> String {
        let (stable, volatile) = assembleChatPromptSplit(from: package)
        if volatile.isEmpty { return stable }
        if stable.isEmpty { return volatile }
        return stable + "\n\n" + volatile
    }

    /// Builds the chat system prompt as `(stable, volatile)` so the
    /// runtime / diagnostics can reason about which fraction is
    /// reusable across turns.
    ///
    /// **Stable** blocks (identical across every turn of a session,
    /// independent of the user's current question):
    ///   - L0a persona, hard rules
    ///   - L0b tone + style (depends only on user.preferredResponseStyle)
    ///   - L0c user profile
    ///   - L0d user memory block
    ///   - L0e language policy (extracted from contextRail)
    ///   - Privacy guardrail
    ///
    /// **Volatile** blocks (recomputed every turn — semantic retrieval,
    /// time-of-day, dynamic skill set):
    ///   - Date/time + location (from contextRail)
    ///   - Tool policy (depends on per-turn `availableTools`)
    ///   - L0.5 conversation summary
    ///   - L0.6 conversation recall
    ///   - L1 facts
    ///   - L2 episodes
    ///   - L3 file excerpts
    ///   - L4 skill instructions
    ///
    /// The boundary is conservative — anything that COULD vary on a
    /// per-turn basis goes into volatile, even if in practice it's
    /// usually stable (e.g. `availableTools`). Better to miss a
    /// potential cache hit than to invalidate the cache because a
    /// "stable" block changed unexpectedly.
    private func assembleChatPromptSplit(
        from package: PromptContextPackage
    ) -> (stable: String, volatile: String) {
        var stableChunks: [String] = []
        var volatileChunks: [String] = []

        // Weak instruction-follower (Gemma 3n, Phi-3 Mini, unknown
        // small models): emit a leaner prompt. Long multi-section
        // system prompts demonstrably correlate with mode collapse
        // and language bleed on these models — we drop:
        //   * hard-rules block (saves ~250 tokens; rules still in persona)
        //   * verbatim conversation recall (summary-only is enough)
        //   * file excerpts (rarely useful for small models, big cost)
        //   * episodes (summary already captures gist)
        //   * tightened fact / recall caps applied below
        // Persona, tone, profile, facts (capped), context rail,
        // tool instructions, language policy, and privacy guardrail
        // stay — they're load-bearing for correctness.
        let isWeak = package.modelCapabilityProfile?.isWeakInstructionFollower ?? false

        // L0a. Assistant persona base
        stableChunks.append(package.assistant.systemPromptBase)

        // L0a'. Hard rules (STABLE) — same wording every turn.
        // Skipped for weak models: the persona already covers the
        // essentials and the long enumerated list seems to teach
        // weak models to enumerate everything in replies.
        if package.settings.guardrailsConfig.hardRulesEnabled && !isWeak {
            stableChunks.append("""
            Hard rules (follow ALL of them):
            1. Output plain Markdown only. NEVER emit chat-template control \
            tokens (e.g. <|im_start|>, <|eot_id|>, <start_of_turn>, [INST], </s>) \
            or role headers like "assistant:" / "user:". Those are wire-format \
            only and must never appear in your visible reply.
            2. If you don't know something, say so plainly. Do NOT invent names, \
            dates, prices, URLs, or quotes. When uncertain, ask a clarifying \
            question or state the limit of your knowledge.
            3. Follow the Language policy block exactly. Never mix scripts \
            inside a single reply unless quoting code or a proper name.
            4. Write ONE coherent answer. Do not repeat the user's question, do \
            not roleplay both sides of the conversation, do not continue with a \
            new "User:" turn after your reply.
            5. Use Markdown sparingly: short paragraphs, lists only when they \
            help, fenced code blocks for code. Never wrap a one-line answer in \
            a list or heading.
            6. Always give a complete answer of at least 2 sentences. \
            If you cannot answer, briefly explain why.
            """)
        }

        // Minimum-response guard for weak models. Strong models get the
        // same rule via the hard-rules block above. Weak models skip hard
        // rules entirely but still need this single line — without it,
        // small quantised models (≤3B) frequently produce 1–2 word replies
        // or a bare sentence fragment when the system prompt is lean.
        if isWeak {
            stableChunks.append("""
            Always answer with at least 2 complete sentences. \
            If you cannot answer the question, briefly explain why.
            """)

            // Anti-mimicry rail. Small models reproduce the dominant surface
            // structure of their context, and this system prompt is mostly
            // bulleted rule blocks — `PromptBuilder.toolPolicyBlock` alone
            // emits 4-6 lines all starting with "- " when WebSearch is on,
            // which on a ~1500-token prompt is a large share of what the model
            // sees. The observed result on Gemma 2 2B was a reply formatted as
            // three bullets no matter what was asked.
            //
            // Naming the cause works better on small checkpoints than a bare
            // "don't use lists": they follow rules that come with a reason far
            // more reliably than prohibitions. Kept to three sentences because
            // this is the tier that can least afford the tokens.
            stableChunks.append("""
            Formatting: write your reply as ordinary prose sentences. The \
            instructions above are written as bullet lists for your reference \
            only — do not copy that shape into your answer. Use bullets ONLY \
            when the user explicitly asks for a list, or when the answer really \
            is three or more parallel items of the same kind.
            """)
        }

        // L0a''. Explain the <context> envelope (STABLE — same wording every
        // turn, so it costs one cache entry, not one per turn).
        //
        // `MLXRuntime.generate` prepends the volatile half of this prompt to
        // the current user turn wrapped in <context>…</context>, so that
        // per-turn churn (date, recall, facts, episodes) reaches the model
        // without invalidating the cached KV prefix. That design is right, but
        // until now nothing told the model what the tag meant — app-supplied
        // background arrived looking exactly as if the user had typed it,
        // immediately before their real question, on every multi-turn message.
        //
        // This codebase already documents the same failure shape one layer
        // down: verbatim recall is dropped for weak models because it is "the
        // single largest source of prompt-injection-style confusion we've seen
        // on Gemma 3n" (see appendRecall below), with the model echoing
        // recalled fragments instead of answering. An unlabelled block glued to
        // the front of the question is that same trap, fired far more often.
        //
        // Kept to three lines deliberately: it is load-bearing for correctness
        // on every turn, and weak models are exactly the ones that both need it
        // most and can least afford the tokens.
        stableChunks.append("""
        Some user messages begin with a <context>…</context> block. That block \
        is background information supplied by the app, NOT something the user \
        wrote or asked about. Use it to inform your answer when relevant. Never \
        quote it, never repeat it back, never answer it — reply only to the \
        text that follows the closing </context> tag.
        """)

        // L0b. Tone + style hints (STABLE — only changes when the user
        // edits their `preferredResponseStyle` in Settings).
        stableChunks.append("""
        Tone: \(package.assistant.tone.label.lowercased()). \
        Preferred response style: \(package.user.preferredResponseStyle.label.lowercased()) — \
        \(package.user.preferredResponseStyle.blurb)
        """)

        // L0c. User profile (STABLE — derived from onboarding).
        appendUserProfile(from: package, to: &stableChunks)

        // L0d. User memory (STABLE within a session — UserMemoryStore
        // doesn't usually change mid-conversation; even when it does,
        // the cost of a single cache invalidation beats inlining it
        // into the volatile half on every turn).
        if let block = package.userMemoryBlock, !block.isEmpty {
            stableChunks.append(block)
        }

        // L0bʹ. Context rail split into stable + volatile halves.
        //
        // **Stable side** (location, language policy, tool policy,
        // answer-length style): these are pure functions of `AppSettings`
        // and `availableTools` — only change when the user flips a
        // toggle in Settings. ~200-300 tokens of static boilerplate
        // that used to invalidate the MLX KV-cache prefix every turn
        // (because the volatile-side date stamp would change), forcing
        // a full re-prefill of everything above.
        //
        // **Volatile side** (date + local time + weak-model guards):
        // the only genuinely per-turn churn. Lives in the user-turn
        // `<context>` injection so the cached prefix stays valid.
        //
        // Net effect on Gemma 3n / Llama 1B (weak models with full
        // lean-mode rail): cached prefix grows from ~800-1000 tokens
        // to ~1200-1500 tokens; volatile shrinks from ~600-900 to
        // ~80-150. Multi-turn time-to-first-token drops measurably
        // because the cached prefix covers everything except the
        // date and the user's actual question.
        let railCtx = PromptBuilder.Context.live(
            settings: package.settings,
            availableTools: package.availableTools,
            isWeakInstructionFollower: isWeak
        )
        stableChunks.append(PromptBuilder.contextRailStable(railCtx))
        volatileChunks.append(PromptBuilder.contextRailVolatile(railCtx))

        // L0.5: Summary of older messages (VOLATILE).
        if let summary = package.conversationSummary {
            volatileChunks.append("""
            Earlier in this conversation (condensed summary — may be incomplete):
            \(summary)
            """)
        }

        // L0.6: Verbatim recall of specific earlier turns (VOLATILE).
        // Skipped for weak models — the summary at L0.5 covers the
        // same information without the per-turn quoting overhead,
        // and the verbatim block is the single largest source of
        // prompt-injection-style confusion we've seen on Gemma 3n
        // ("Štěpánu, vecera je svá" — model echoing fragments from
        // recalled turns instead of answering the current question).
        if !package.conversationRecall.isEmpty && !isWeak {
            // Hard cap to top 3 entries even for strong models —
            // anything beyond that is rarely on-topic and just
            // burns context budget.
            let recall = package.conversationRecall.prefix(3)
            volatileChunks.append("""
            Relevant earlier turns from this conversation (recalled by similarity to the current question — quote verbatim if asked, otherwise treat as background context):
            \(recall.joined(separator: "\n\n"))
            """)
        }

        // L1. Durable facts (VOLATILE — semantic retrieval per turn).
        // Cap is tighter for weak models so the prompt stays under
        // the ~600-token "lean" target.
        if package.settings.guardrailsConfig.factsEnabled {
            appendFacts(from: package, to: &volatileChunks, limit: isWeak ? 3 : 8)
        }

        // L2. Episodic summaries (VOLATILE).
        // Dropped entirely for weak models — episodes are
        // higher-level than facts and weak models can't reliably
        // disambiguate them from the current turn.
        if package.settings.guardrailsConfig.episodesEnabled && !isWeak {
            appendEpisodes(from: package, to: &volatileChunks)
        }

        // L3. Source excerpts (VOLATILE — depends on attached files).
        // Big block. Weak models can't follow "use this excerpt only
        // when answering" instruction reliably, so we drop it.
        if package.settings.guardrailsConfig.fileExcerptsEnabled && !isWeak {
            appendFileExcerpts(from: package, to: &volatileChunks)
        }

        // L4. Agentic tool instructions (STABLE — `SkillManager.renderInstructions`
        // is a pure function of the enabled-tool set, which only mutates
        // when the user toggles a skill in Settings. Previously volatile,
        // which invalidated the KV-cache prefix every turn for ~150–200
        // tokens of static boilerplate. Moving to stable preserves the
        // cache across turns; toggling a skill correctly invalidates the
        // cache because the rendered string changes.
        if package.settings.guardrailsConfig.skillInstructionsEnabled,
           let skills = package.skillInstructions, !skills.isEmpty {
            stableChunks.append(skills)
        }

        // Privacy guardrail (STABLE — wording depends on availableTools
        // which lives in volatile, but the actual privacy text is the
        // same per-policy and produced from a fixed lookup table).
        if package.settings.guardrailsConfig.privacyGuardrailEnabled {
            stableChunks.append(privacyGuardrail(for: package))
        }

        return (
            stable: stableChunks.joined(separator: "\n\n"),
            volatile: volatileChunks.joined(separator: "\n\n")
        )
    }

    // MARK: - Tool followup (post-action loop iteration)

    private func assembleToolFollowupPrompt(from package: PromptContextPackage) -> String {
        var chunks: [String] = []
        let isWeak = package.modelCapabilityProfile?.isWeakInstructionFollower ?? false

        // L0a. Persona (same as chat — the model should stay in character)
        chunks.append(package.assistant.systemPromptBase)

        // L0b. Tone
        chunks.append("""
        Tone: \(package.assistant.tone.label.lowercased()). \
        Preferred response style: \(package.user.preferredResponseStyle.label.lowercased()) — \
        \(package.user.preferredResponseStyle.blurb)
        """)

        // Context rail — stripped to date/language/style only. The full tool
        // policy is omitted here: the model already called a tool, the
        // observation is in history, and the short tool reminder below covers
        // the "don't call again unless necessary" constraint. Repeating the
        // full policy wastes tokens and can confuse small models into thinking
        // they should issue another tool call.
        let followupCtx = PromptBuilder.Context.live(
            settings: package.settings,
            availableTools: package.availableTools,
            isWeakInstructionFollower: isWeak
        )
        chunks.append(PromptBuilder.contextBlock(followupCtx))
        chunks.append(PromptBuilder.languageBlock(followupCtx))
        chunks.append(PromptBuilder.styleBlock(followupCtx))

        // L0c. User profile (helpful for personalised follow-up)
        appendUserProfile(from: package, to: &chunks)

        // L1/L2. Reduced fact and episode window for followup turns — the model
        // only needs enough context to personalise the answer, not the full set.
        appendFacts(from: package, to: &chunks, limit: 3)
        appendEpisodes(from: package, to: &chunks)

        // Short, direct tool reminder. Prevents the model from repeating
        // instructions and gets straight to the user's answer.
        // Min-length guard appended here: toolFollowup is the one place where
        // small models routinely produce a single word or a bare noun after
        // seeing the <Observation> tag, because the abbreviated prompt leaves
        // them with no explicit output-length signal. The .chat path has this
        // guard in the stable system chunks; for toolFollowup we bake it into
        // the tool reminder so both entry-points are covered.
        chunks.append("""
        Tool Observation: Use the provided <Observation> to answer the user. \
        Be direct and natural, and always answer with at least 2 complete \
        sentences. Do NOT use another tool unless the observation is missing \
        critical data.
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
        text — no preamble, no labels. \
        Use the same language as the conversation (if the conversation is in Czech, summarize in Czech).
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
        - Write all extracted content in the same language as the conversation \
        (Czech if the conversation is in Czech).
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

    private func appendFacts(from package: PromptContextPackage, to chunks: inout [String], limit: Int = 8) {
        guard !package.facts.isEmpty else { return }
        // Dynamic per-fact character cap.
        //
        // Allocates ~1/8 of the model's `safeHistoryTokenBudget` to the
        // entire facts block, then divides by `limit` to get a
        // per-fact ceiling. At 4 chars/token (Latin script) that maps
        // budget → chars. Examples:
        //   - tight iPhone (budget 600):    cap ≈ 600/8/3 × 4 ≈ 100 chars/fact
        //   - moderate iPhone (1400):       cap ≈ 230 chars/fact
        //   - generous iPad (2800):         cap ≈ 466 chars/fact
        //
        // Strong-instruction-follower profiles bypass the cap entirely
        // — they cope with long facts and the user can rely on
        // verbatim recall for paste-in memories. The cap exists to
        // protect small models from a single 500-char fact crowding
        // out the rest of the volatile budget.
        let isWeak = package.modelCapabilityProfile?.isWeakInstructionFollower ?? false
        let budget = package.modelCapabilityProfile?.safeHistoryTokenBudget ?? 1400
        let perFactCap: Int
        if !isWeak {
            perFactCap = Int.max
        } else {
            let factsBudgetTokens = max(40, budget / 8)
            // 4 chars/token, divided across `limit` facts, floor at
            // 80 chars (anything shorter truncates useful facts).
            perFactCap = max(80, factsBudgetTokens * 4 / max(1, limit))
        }
        let factLines = package.facts.prefix(limit).map { fact -> String in
            let raw = fact.content
            // Cap is calibrated in BPE-token-proxy units, which align
            // more closely with Unicode scalars than with Swift's
            // Character / grapheme-cluster `count`. A single emoji is
            // one Character but 4–6 BPE pieces; a CJK character is one
            // Character but ~1 token; flag emoji are 2 scalars and
            // routinely 8+ tokens. Switching to `unicodeScalars.count`
            // brings the cap closer to the real budget impact across
            // scripts at the cost of a few percent over-truncation on
            // pure Latin text (which still over-counts diacritics into
            // 2 scalars). When truncating we cut on Character
            // boundaries to avoid producing an orphan combining mark.
            let measure = raw.unicodeScalars.count
            if measure <= perFactCap { return "- \(raw)" }
            // Approximate scalar→character ratio so the truncated
            // prefix targets the cap measured in scalars while still
            // slicing on grapheme boundaries.
            let avgScalarsPerChar = max(1, measure / max(1, raw.count))
            let charCap = max(1, perFactCap / avgScalarsPerChar)
            return "- \(raw.prefix(charCap))…"
        }
        chunks.append("""
        Remembered facts (user-controlled, may be incomplete):
        \(factLines.joined(separator: "\n"))
        """)
    }

    private func appendEpisodes(from package: PromptContextPackage, to chunks: inout [String], limit: Int = 3) {
        guard !package.episodes.isEmpty else { return }
        // Episode lines carry a "from N days ago" relative timestamp
        // so the model can reason about freshness ("you talked about
        // this last week" vs "you talked about this an hour ago").
        // Source-conversation provenance is implicit — the episode
        // came from a different chat by definition (we're injecting
        // it into the current one), so the date hint plus the gist
        // is enough for the model to anchor it.
        let now = Date()
        let episodeLines = package.episodes.prefix(limit).map { episode -> String in
            let ageDays = Int(now.timeIntervalSince(episode.createdAt) / 86_400)
            let when: String
            switch ageDays {
            case 0:        when = "today"
            case 1:        when = "yesterday"
            case 2...6:    when = "\(ageDays) days ago"
            case 7...13:   when = "last week"
            case 14...29:  when = "\(ageDays / 7) weeks ago"
            default:       when = "\(ageDays / 30) months ago"
            }
            return "- (\(when)) \(episode.summary)"
        }
        chunks.append("""
        Recent context (episodic recall from earlier conversations, may be outdated — the date hint shows how fresh each item is):
        \(episodeLines.joined(separator: "\n"))
        """)
    }

    private func appendFileExcerpts(from package: PromptContextPackage, to chunks: inout [String]) {
        // Drop empty / whitespace-only excerpts. Without this filter
        // a failed extraction (e.g. URL ingest that produced a
        // marker-only stub, or a chunker that survived an all-noise
        // page) would still surface as "the user attached …" — the
        // model would then either hallucinate or apologise. Both
        // are worse than not advertising context that doesn't exist.
        let usable = package.fileExcerpts.compactMap { excerpt -> String? in
            let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !usable.isEmpty else { return }
        // Explicit, numbered delimiters so the model never confuses
        // an excerpt body with the user's actual prompt. The
        // boundary phrasing is intentionally tight: "do not invent",
        // "cite by number", "if absent say so" — all three failure
        // modes we've actually seen in chat logs.
        let blocks = usable.enumerated().map { idx, body in
            """
            === RETRIEVED CONTEXT [\(idx + 1)] ===
            \(body)
            === END CONTEXT [\(idx + 1)] ===
            """
        }
        chunks.append("""
        The user attached the following retrieved context to their message. \
        It comes from documents or web pages they imported earlier — treat \
        it as a primary source, but do NOT invent details not present in it. \
        If the answer is not in any block, say so explicitly. When citing, \
        reference the block number (e.g. "per context [2]").
        \(blocks.joined(separator: "\n\n"))
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
