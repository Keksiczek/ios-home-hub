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
    
    private init() {
        // Register default skills
        register(CalculatorSkill())
        register(WebSearchSkill())
        register(CalendarSkill())
        register(HomeKitSkill())
        register(RemindersSkill())
    }
    
    func register(_ skill: any Skill) {
        skills[skill.name.lowercased()] = skill
    }
    
    /// Generates L4 Prompt string explaining all available skills.
    func buildSystemInstructions() -> String {
        guard !skills.isEmpty else { return "" }
        
        var instructions = "You have access to the following native tools/skills:\n"
        for (_, skill) in skills {
            instructions += "- \(skill.name): \(skill.description)\n"
        }
        
        instructions += """

        To use a tool, you MUST reply with the exact format:
        <Action:SkillName:Input>
        
        For example, if you want to calculate 2+2, you output:
        <Action:Calculator:2+2>
        
        Important rules for tool use:
        1. When you output an <Action:...> tag, STOP generation immediately. Do NOT output anything else.
        2. The system will process your action and provide you with an <Observation:Result>.
        3. Once you receive the observation, use that information to formulate your final user-facing response.
        4. Do NOT fake observations or guess the result. Always wait for the actual <Observation:>.
        """
        
        return instructions
    }
    
    /// Parses any <Action:Name:Input> from text.
    func parseAction(from text: String) -> ActionCommand? {
        let pattern = "<Action:([^:]+):([^>]+)>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else {
            return nil
        }
        
        let nsText = text as NSString
        let name = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let input = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        let fullTag = nsText.substring(with: match.range)
        
        return ActionCommand(skillName: name, input: input, fullTag: fullTag)
    }
    
    /// Executes the specified skill command.
    func execute(_ command: ActionCommand) async -> String {
        guard let skill = skills[command.skillName.lowercased()] else {
            return "Error: Skill '\(command.skillName)' is not recognized."
        }
        
        do {
            let result = try await skill.execute(input: command.input)
            return result
        } catch {
            return "Error executing \(command.skillName): \(error.localizedDescription)"
        }
    }
}
