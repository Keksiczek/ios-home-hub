import Foundation

struct ActionCommand: Equatable {
    let skillName: String
    let input: String
    let fullTag: String // e.g. "<Action:Calculator:2+2>"
}

/// Central registry for all tools available to the Agent.
///
/// The registry is **the superset**: all skills the app knows how to run
/// live here. Which of them actually surface to the model on any given
/// turn is decided at call time by the `enabled` allow-list (sourced
/// from `AppSettings.enabledTools`). This lets the user toggle individual
/// tools in Settings without forcing the prompt assembler to know about
/// skills the manager hasn't registered yet.
actor SkillManager {
    static let shared = SkillManager()

    private var skills: [String: any Skill] = [:]

    /// Cached `renderInstructions` output, keyed by the lowercased set
    /// of enabled skill names. A different allow-list invalidates the
    /// cache but a repeated turn with the same allow-list is free.
    private var cachedInstructions: (enabled: Set<String>, text: String)?

    private init() {
        // WebSearchSkill stays out of the default registration: it needs
        // explicit user consent AND an available network, and the prompt
        // assembler's privacy rail flips based on whether it's registered.
        // Call `register(WebSearchSkill())` from onboarding / settings once
        // the user opts in.
        let defaults: [any Skill] = [
            CalculatorSkill(),
            CalendarSkill(),
            HomeKitSkill(),
            RemindersSkill(),
            DeviceInfoSkill()
        ]
        for skill in defaults {
            skills[skill.name.lowercased()] = skill
        }
    }

    func register(_ skill: any Skill) {
        skills[skill.name.lowercased()] = skill
        cachedInstructions = nil
    }

    /// The names of every skill currently in the registry, in registration
    /// order-independent form. Used by `ConversationService` to compute
    /// the intersection with `AppSettings.enabledTools` for each turn.
    func registeredSkillNames() -> Set<String> {
        Set(skills.values.map(\.name))
    }

    /// Generates the L4 system-prompt block listing the *enabled* skills.
    ///
    /// - Parameter enabled: Allow-list of skill names (case-insensitive)
    ///   that should surface to the model. Skills outside this set are
    ///   omitted even if registered. Pass `nil` to include every
    ///   registered skill (legacy behaviour for older callers).
    func buildSystemInstructions(enabled: Set<String>? = nil) -> String {
        let allow: Set<String> = enabled.map { Set($0.map { $0.lowercased() }) }
            ?? Set(skills.keys)

        if let cached = cachedInstructions, cached.enabled == allow {
            return cached.text
        }

        let built = renderInstructions(enabled: allow)
        cachedInstructions = (allow, built)
        return built
    }

    private func renderInstructions(enabled: Set<String>) -> String {
        let visible = skills
            .filter { enabled.contains($0.key) }
            .values
            .sorted { $0.name < $1.name }

        guard !visible.isEmpty else { return "" }

        var instructions = "You have access to the following native tools/skills:\n"
        for skill in visible {
            instructions += "- \(skill.name): \(skill.description)\n"
        }

        instructions += """

        To use a tool, emit a single `<tool_call>` block containing a JSON object \
        with a `name` field (skill name) and an `input` field (argument string):

        <tool_call>{"name": "Calculator", "input": "25 * 4 + 10"}</tool_call>

        Important rules:
        1. Output ONLY the `<tool_call>` block — stop immediately after `</tool_call>`. Add nothing else.
        2. The `<tool_call>` block must be on a single line. No prose before or after it on that line.
        3. `input` is a plain string. Do not nest JSON, do not manually escape quotes inside `input`.
        4. The system executes the tool and returns the result in an `<Observation>` block.
        5. Use the observation to write your final user-facing response.
        6. Never fabricate an observation or guess the result. Always wait for the real `<Observation>`.
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
    ///
    /// - Parameters:
    ///   - command: Parsed envelope from the model.
    ///   - enabled: Allow-list of skill names. A command whose skill is
    ///     registered but disabled is rejected with an error string so
    ///     the LLM can incorporate the refusal into its next turn
    ///     instead of the tool silently running against user intent.
    ///     Pass `nil` to skip the allow-list check.
    func execute(_ command: ActionCommand, enabled: Set<String>? = nil) async -> String {
        let key = command.skillName.lowercased()
        guard let skill = skills[key] else {
            return "Error: Skill '\(command.skillName)' is not recognized."
        }
        if let enabled, !enabled.map({ $0.lowercased() }).contains(key) {
            return "Error: Skill '\(command.skillName)' is currently disabled in Settings."
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
