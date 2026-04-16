import Foundation

/// Pure function layer. Turns a `PromptContextPackage` into the
/// `RuntimePrompt` the runtime actually sees. No side effects, no
/// state — trivial to unit test.
///
/// v2 layered memory assembly:
///
/// L0: Assistant persona + tone + style + user profile
/// L1: Approved durable facts (pinned + keyword-scored)
/// L2: Relevant episodic summaries
/// L3: (future) Source excerpts, loaded only when strongly relevant
///
/// Privacy guardrails + recent conversation messages + current input
/// follow the memory layers.
@MainActor
final class PromptAssemblyService {

    /// Hard cap on the number of tokens we allow the conversation history to
    /// occupy in the assembled prompt. Conservative on purpose:
    ///   - typical n_ctx = 4096
    ///   - system prompt ≈ 400–600 tokens
    ///   - maxNewTokens reservation ≈ 512
    ///   - remaining ≈ 1200 tokens for history is safe across all supported models.
    private static let maxHistoryTokenBudget: Int = 1200

    /// Rough tokens-per-character estimate used to keep the history within the
    /// budget without tokenising (which requires loading the model). Conservative —
    /// actual ratios are typically ~0.25 for English; 0.35 adds margin for code,
    /// non-Latin scripts, and BPE artefacts.
    private static let avgTokensPerChar: Double = 0.35

    func build(from package: PromptContextPackage) -> RuntimePrompt {
        let system = assembleSystemPrompt(from: package)

        // Trim the recent-messages window to a conservative character budget so
        // the assembled prompt never exceeds n_ctx. We keep the most recent
        // messages and drop older ones first.
        let historyBudgetChars = Int(Double(Self.maxHistoryTokenBudget) / Self.avgTokensPerChar)
        var charCount = 0
        let trimmedMessages = package.recentMessages.reversed().filter { msg in
            charCount += msg.content.count
            return charCount <= historyBudgetChars
        }.reversed()

        var runtimeMessages: [RuntimeMessage] = trimmedMessages.compactMap { m in
            switch m.role {
            case .user:      return RuntimeMessage(role: .user, content: m.content)
            case .assistant: return RuntimeMessage(role: .assistant, content: m.content)
            case .system:    return nil
            }
        }

        runtimeMessages.append(RuntimeMessage(role: .user, content: package.userInput))
        return RuntimePrompt(systemPrompt: system, messages: runtimeMessages)
    }

    private func assembleSystemPrompt(from package: PromptContextPackage) -> String {
        var chunks: [String] = []

        // L0a. Assistant persona base
        chunks.append(package.assistant.systemPromptBase)

        // L0b. Tone + style hints
        chunks.append("""
        Tone: \(package.assistant.tone.label.lowercased()). \
        Preferred response style: \(package.user.preferredResponseStyle.label.lowercased()) — \
        \(package.user.preferredResponseStyle.blurb)
        """)

        // L0c. User profile
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

        // L0.5: Summary of older messages when the conversation exceeds the window.
        if let summary = package.conversationSummary {
            chunks.append("""
            Earlier in this conversation (condensed summary — may be incomplete):
            \(summary)
            """)
        }

        // L1. Durable facts — conservative cap to stay within context budget.
        if !package.facts.isEmpty {
            let factLines = package.facts.prefix(8).map { "- \($0.content)" }
            chunks.append("""
            Remembered facts (user-controlled, may be incomplete):
            \(factLines.joined(separator: "\n"))
            """)
        }

        // L2. Episodic summaries — kept small; episodes are verbose and consume context.
        if !package.episodes.isEmpty {
            let episodeLines = package.episodes.prefix(3).map { "- \($0.summary)" }
            chunks.append("""
            Recent context (episodic, may be outdated):
            \(episodeLines.joined(separator: "\n"))
            """)
        }

        // L3. Source excerpts — injected context from attached files
        if !package.fileExcerpts.isEmpty {
            let fileLines = package.fileExcerpts.map { "--- FILE EXCERPT ---\n\($0)\n--- END EXCERPT ---" }
            chunks.append("""
            The user attached the following file contents to their message. Use this provided information to answer their prompt, but do not fabricate information if the answer is not in the text:
            \(fileLines.joined(separator: "\n\n"))
            """)
        }
        
        // L4. Available Agentic Tools
        if let skills = package.skillInstructions, !skills.isEmpty {
            chunks.append(skills)
        }

        // Privacy guardrails
        chunks.append("""
        Never fabricate personal details about the user. If you're \
        unsure, ask or say you don't know. You run entirely on-device \
        with no network access — don't pretend to look anything up.
        """)

        return chunks.joined(separator: "\n\n")
    }
}
