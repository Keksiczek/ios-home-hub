import Foundation

struct ActionCommand: Equatable {
    let skillName: String
    let input: String
    let fullTag: String // e.g. "<Action:Calculator:2+2>"
}

/// Central registry for all tools available to the Agent.
actor SkillManager {
    static let shared = SkillManager()

    private var skills: [String: any Skill] = [:]

    /// Cached output of `buildSystemInstructions()`. Cleared on every
    /// `register(_:)` call. Skills are otherwise immutable, so this is
    /// safe to memoise across the per-turn calls in `ConversationService`.
    private var cachedInstructions: String?

    private init() {
        // WebSearchSkill is intentionally omitted from the default registration.
        // PromptAssemblyService injects an on-device privacy guardrail
        // ("You run entirely on-device with no network access…") that directly
        // contradicts any web-search tool instructions. The model would behave
        // unpredictably if both were present. Register WebSearchSkill explicitly
        // via `register(_:)` once real network-enabled search is wired up and
        // the privacy guardrail is made conditional.
        let defaults: [any Skill] = [
            CalculatorSkill(), CalendarSkill(), HomeKitSkill(), RemindersSkill()
        ]
        for skill in defaults {
            skills[skill.name.lowercased()] = skill
        }
    }

    func register(_ skill: any Skill) {
        skills[skill.name.lowercased()] = skill
        cachedInstructions = nil
    }

    /// Generates L4 Prompt string explaining all available skills.
    /// Result is cached until the next `register(_:)` call so the
    /// per-turn invocation in `ConversationService.performSend` is free
    /// after the first build.
    func buildSystemInstructions() -> String {
        if let cachedInstructions {
            return cachedInstructions
        }

        let built = renderInstructions()
        cachedInstructions = built
        return built
    }

    private func renderInstructions() -> String {
        guard !skills.isEmpty else { return "" }

        var instructions = "You have access to the following native tools/skills:\n"
        for (_, skill) in skills {
            instructions += "- \(skill.name): \(skill.description)\n"
        }

        instructions += """

        To use a tool, emit a single `<tool_call>` block containing a JSON object \
        with a `name` field (skill name) and an `input` field (argument string):

        <tool_call>{"name": "Calculator", "input": "25 * 4 + 10"}</tool_call>

        Important rules:
        1. Output ONLY the `<tool_call>` block — stop immediately after `</tool_call>`. Add nothing else.
        2. The system executes the tool and returns the result in an `<Observation>` block.
        3. Use the observation to write your final user-facing response.
        4. Never fabricate an observation or guess the result. Always wait for the real `<Observation>`.
        5. Write `input` as a plain string. Do not nest JSON or manually escape quotes inside `input`.
        """

        return instructions
    }

    /// Parses the first `<tool_call>` envelope in `text`.
    ///
    /// Returns `nil` if no valid envelope is present, the JSON is malformed,
    /// or either the `name` or `input` field is missing.
    func parseAction(from text: String) -> ActionCommand? {
        ToolCallEnvelope.parse(from: text)?.toActionCommand()
    }
    
    /// Executes the specified skill command.
    /// Errors are caught and rendered as `"Error executing …"` strings so
    /// the LLM can incorporate them into its `<Observation>` reasoning
    /// without crashing the agentic loop.
    func execute(_ command: ActionCommand) async -> String {
        guard let skill = skills[command.skillName.lowercased()] else {
            return "Error: Skill '\(command.skillName)' is not recognized."
        }

        do {
            return try await skill.execute(input: command.input)
        } catch {
            return "Error executing \(command.skillName): \(error.localizedDescription)"
        }
    }

    /// Like `execute(_:)` but rethrows the underlying skill error instead
    /// of stringifying it. Used by callers (widget action handler, App
    /// Intents) that need structured success/failure detection rather
    /// than a localised keyword scan.
    ///
    /// Throws `SkillManagerError.unknownSkill` when the skill name does
    /// not resolve; rethrows whatever the skill itself raised on error.
    func executeThrowing(_ command: ActionCommand) async throws -> String {
        guard let skill = skills[command.skillName.lowercased()] else {
            throw SkillManagerError.unknownSkill(name: command.skillName)
        }
        return try await skill.execute(input: command.input)
    }
}

enum SkillManagerError: LocalizedError, Equatable {
    case unknownSkill(name: String)

    var errorDescription: String? {
        switch self {
        case .unknownSkill(let name):
            return "Skill '\(name)' is not recognized."
        }
    }
}
