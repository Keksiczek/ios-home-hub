import Foundation

/// JSON payload carried inside `<tool_call>…</tool_call>` blocks.
///
/// ## Wire format (model output)
/// ```
/// <tool_call>{"name": "Calculator", "input": "25 * 4 + 10"}</tool_call>
/// ```
///
/// ## Why JSON-in-tag instead of `<Action:Name:Input>`?
/// The old single-line format breaks on inputs containing `:` (URLs, JSON
/// key-value pairs) or `>` (comparison operators, HTML entities). A JSON
/// payload inside block-tag boundaries handles any character via JSON escaping
/// and is trivially extensible for future fields (`id`, `reason`, etc.).
///
/// ## Field contract
/// - `name`  — exact registered skill name (case-insensitive at execution).
/// - `input` — argument string forwarded verbatim to `Skill.execute(input:)`.
struct ToolCallEnvelope: Decodable, Sendable, Equatable {
    let name: String
    let input: String
}

extension ToolCallEnvelope {

    static let openTag  = "<tool_call>"
    static let closeTag = "</tool_call>"

    /// Extracts and decodes the first `<tool_call>…</tool_call>` block in `text`.
    ///
    /// Returns `nil` when:
    /// - the open or close tag is absent,
    /// - the content between the tags is not valid UTF-8 JSON, or
    /// - either the `name` or `input` field is missing from the JSON object.
    static func parse(from text: String) -> ToolCallEnvelope? {
        guard
            let startRange = text.range(of: openTag),
            let endRange   = text.range(of: closeTag,
                                        range: startRange.upperBound..<text.endIndex)
        else { return nil }

        let json = String(text[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let data = json.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(ToolCallEnvelope.self, from: data)
        else { return nil }

        return envelope
    }

    /// Converts to an `ActionCommand` for the skill execution pipeline.
    func toActionCommand() -> ActionCommand {
        let payload = "{\"name\": \"\(jsonEscape(name))\", \"input\": \"\(jsonEscape(input))\"}"
        return ActionCommand(
            skillName: name,
            input: input,
            fullTag: "\(Self.openTag)\(payload)\(Self.closeTag)"
        )
    }

    // MARK: - Private

    private func jsonEscape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
