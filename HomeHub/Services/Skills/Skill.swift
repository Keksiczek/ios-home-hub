import Foundation

/// Defines a native capability that the LLM can invoke.
protocol Skill: Sendable {
    /// The exact tag name the LLM must emit to trigger this skill.
    /// e.g. "Calculator", "WebSearch"
    var name: String { get }
    
    /// Instructions injected into the system prompt detailing what this skill does
    /// and what the input should look like.
    var description: String { get }
    
    /// Executes the native action with the parsed string argument.
    func execute(input: String) async throws -> String
}
