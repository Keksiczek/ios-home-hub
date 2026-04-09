import Foundation

/// Pure function layer. Turns a `PromptContextPackage` into the
/// `RuntimePrompt` the runtime actually sees. No side effects, no
/// state — trivial to unit test.
///
/// Order of context, from most to least stable:
///
/// 1. Assistant persona + tone + style
/// 2. User personalization profile (name, work, interests, context)
/// 3. Relevant memory facts (pinned + keyword-scored)
/// 4. Privacy guardrails
/// 5. Recent conversation messages (most recent N)
/// 6. Current user input
@MainActor
final class PromptAssemblyService {

    func build(from package: PromptContextPackage) -> RuntimePrompt {
        let system = assembleSystemPrompt(from: package)

        var runtimeMessages: [RuntimeMessage] = package.recentMessages.compactMap { m in
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

        // 1. Assistant persona base
        chunks.append(package.assistant.systemPromptBase)

        // 2. Tone + style hints
        chunks.append("""
        Tone: \(package.assistant.tone.label.lowercased()). \
        Preferred response style: \(package.user.preferredResponseStyle.label.lowercased()) — \
        \(package.user.preferredResponseStyle.blurb)
        """)

        // 3. User profile
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

        // 4. Memory facts
        if !package.facts.isEmpty {
            let factLines = package.facts.prefix(12).map { "- \($0.content)" }
            chunks.append("""
            Remembered facts (user-controlled, may be incomplete):
            \(factLines.joined(separator: "\n"))
            """)
        }

        // 5. Privacy guardrails
        chunks.append("""
        Never fabricate personal details about the user. If you're \
        unsure, ask or say you don't know. You run entirely on-device \
        with no network access — don't pretend to look anything up.
        """)

        return chunks.joined(separator: "\n\n")
    }
}
