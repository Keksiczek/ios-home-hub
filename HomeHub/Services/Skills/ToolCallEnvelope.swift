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
struct ToolCallEnvelope: Codable, Sendable, Equatable {
    let name: String
    let input: String
}

extension ToolCallEnvelope {

    static let openTag  = "<tool_call>"
    static let closeTag = "</tool_call>"

    /// Tag-pair fallbacks for models that emit a different envelope
    /// even after being told to use `<tool_call>`. Order matters:
    /// the parser tries each pair until one yields a non-empty
    /// payload. Listed lower-case; matching is case-insensitive.
    ///
    /// Why we accept these at all when the system prompt mandates
    /// `<tool_call>`: quantized small models (Gemma-3n, Phi-3, etc.)
    /// drift back to whatever envelope their pre-training reinforced
    /// most strongly. Refusing the alternates means the user sees
    /// the wrapper tags as raw text and gets no tool result; accepting
    /// them costs nothing because the decoder still validates the
    /// JSON shape and the allow-list filters at dispatch.
    private static let envelopePairs: [(open: String, close: String)] = [
        ("<tool_call>",      "</tool_call>"),
        ("<function_call>",  "</function_call>"),
        ("<function>",       "</function>"),
        ("<tool>",           "</tool>"),
        ("[TOOL_CALLS]",     "[/TOOL_CALLS]"),
        // Llama 3.1 native — `<|python_tag|>` followed by JSON, then
        // any of the EOT markers (`<|eom_id|>`, `<|eot_id|>`, or end
        // of text). Treat the EOT-less form as ending at the first
        // newline OR end of string in `extractPythonTagPayload`.
        ("<|python_tag|>",   "<|eom_id|>"),
        ("<|python_tag|>",   "<|eot_id|>")
    ]

    /// Extracts and decodes the first recognised tool-call envelope in `text`.
    ///
    /// Recognised forms (tried in order):
    ///   1. `<tool_call>…</tool_call>` (canonical)
    ///   2. `<function_call>` / `<function>` / `<tool>` variants
    ///   3. `[TOOL_CALLS]…[/TOOL_CALLS]` (Mistral)
    ///   4. `<|python_tag|>…<|eom_id|>` (Llama 3.1)
    ///   5. Bare JSON object containing the required fields, optionally
    ///      wrapped in a `\`\`\`json … \`\`\`` markdown block.
    ///
    /// Field-name flexibility: the JSON may use `name|tool|function`
    /// for the skill name and `input|arguments|args|params` for the
    /// argument. Both string-typed values and JSON-object arguments
    /// are accepted (objects get re-serialised to a JSON string so
    /// `Skill.execute(input:)` always receives a String).
    ///
    /// Returns `nil` when no recognised form is present or the
    /// payload doesn't decode into a usable envelope.
    static func parse(from text: String) -> ToolCallEnvelope? {
        // Try every wrapped form first — they delimit the payload
        // unambiguously, which is more reliable than scanning for
        // a bare `{` (text often contains JSON-looking prose).
        for pair in envelopePairs {
            if let payload = extractBetween(text, open: pair.open, close: pair.close),
               let env = decodeFlexible(payload) {
                return env
            }
        }
        // Llama 3.1 EOT-less form: payload ends at newline or EOS.
        if let payload = extractPythonTagPayload(text),
           let env = decodeFlexible(payload) {
            return env
        }
        // Last resort: a bare JSON object somewhere in the text. We
        // only attempt this when the text looks like it WAS trying
        // to call a tool (mentions the open tag substring or a known
        // field name) — otherwise every plain reply containing a
        // JSON-shaped substring would be misclassified.
        if looksLikeToolCallAttempt(text),
           let payload = extractFirstJSONObject(text),
           let env = decodeFlexible(payload) {
            return env
        }
        return nil
    }

    // MARK: - Helpers

    /// Case-insensitive search for `open...close`, returning the
    /// (trimmed) content in between. Strips a wrapping
    /// `\`\`\`json … \`\`\`` markdown fence if present.
    private static func extractBetween(_ text: String, open: String, close: String) -> String? {
        guard let startRange = text.range(of: open, options: .caseInsensitive) else { return nil }
        guard let endRange = text.range(
            of: close,
            options: .caseInsensitive,
            range: startRange.upperBound..<text.endIndex
        ) else { return nil }
        var payload = String(text[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("```") {
            if let newlineIndex = payload.firstIndex(of: "\n") {
                payload = String(payload[payload.index(after: newlineIndex)...])
            }
            if payload.hasSuffix("```") { payload = String(payload.dropLast(3)) }
            payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return payload.isEmpty ? nil : payload
    }

    /// Llama 3.1 emits `<|python_tag|>{json}` with no closing wrapper
    /// when the chat template doesn't append the EOT id. Treat the
    /// rest of the first line (or the rest of the string if the JSON
    /// spans multiple lines) as the payload, taking only the first
    /// balanced `{…}` so subsequent prose doesn't contaminate it.
    private static func extractPythonTagPayload(_ text: String) -> String? {
        let marker = "<|python_tag|>"
        guard let start = text.range(of: marker, options: .caseInsensitive) else { return nil }
        let after = String(text[start.upperBound...])
        return extractFirstJSONObject(after)
    }

    /// Returns the first top-level balanced `{…}` substring, or `nil`
    /// if none exists. Tolerates nested braces inside strings via a
    /// minimal string-aware scanner (skips characters inside `"…"`).
    private static func extractFirstJSONObject(_ text: String) -> String? {
        var depth = 0
        var startIdx: String.Index?
        var inString = false
        var escape = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if escape { escape = false }
            else if ch == "\\" && inString { escape = true }
            else if ch == "\"" { inString.toggle() }
            else if !inString {
                if ch == "{" {
                    if depth == 0 { startIdx = i }
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0, let s = startIdx {
                        return String(text[s...i])
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Heuristic to decide whether a bare-JSON salvage attempt is worth
    /// making. Cheap substring checks; intentionally conservative —
    /// false negatives only mean the model has to be re-prompted,
    /// while false positives would surface plain-text replies as
    /// tool-call attempts.
    private static func looksLikeToolCallAttempt(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("tool_call")
            || lower.contains("\"name\"")
            || lower.contains("\"function\"")
            || lower.contains("\"tool\"")
    }

    /// Decodes a JSON payload into a `ToolCallEnvelope`, tolerating:
    /// - alternate field names (`name|tool|function`, `input|arguments|args|params`)
    /// - a JSON-object argument (re-serialised to a string so
    ///   `Skill.execute(input:)` always gets a `String`)
    /// - leading/trailing whitespace and stray markdown fences
    private static func decodeFlexible(_ payload: String) -> ToolCallEnvelope? {
        guard let data = payload.data(using: .utf8) else { return nil }
        // Fast path: canonical shape.
        if let env = try? JSONDecoder().decode(ToolCallEnvelope.self, from: data),
           !env.name.isEmpty {
            return env
        }
        // Permissive path: parse as `Any` and pick the right keys.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let nameKeys = ["name", "tool", "function", "tool_name"]
        let argKeys  = ["input", "arguments", "args", "params", "parameters"]
        var name: String?
        for key in nameKeys {
            if let v = obj[key] as? String, !v.isEmpty { name = v; break }
        }
        guard let resolvedName = name else { return nil }

        var input = ""
        for key in argKeys {
            if let v = obj[key] as? String { input = v; break }
            if let v = obj[key] {
                // Object/array argument: re-serialise so the skill
                // gets a stable JSON string. Many skills (Calculator,
                // WebSearch) want a flat string anyway; the ones that
                // expect structured input can parse the JSON back.
                if let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
                   let str = String(data: data, encoding: .utf8) {
                    input = str
                    break
                }
            }
        }
        return ToolCallEnvelope(name: resolvedName, input: input)
    }

    /// Converts to an `ActionCommand` for the skill execution pipeline.
    /// `fullTag` is rendered through `JSONEncoder` so callers never have
    /// to hand-escape quotes or worry about embedded JSON breaking the
    /// envelope — the encoder handles every legal Unicode payload.
    func toActionCommand() -> ActionCommand {
        ActionCommand(
            skillName: name,
            input: input,
            fullTag: renderTag()
        )
    }

    /// Renders the `<tool_call>{…}</tool_call>` wire form for `self`.
    /// Falls back to a minimal best-effort string if encoding ever fails
    /// (cannot in practice — `String` always encodes), so callers can
    /// rely on a non-empty tag without a do/catch.
    func renderTag() -> String {
        let payload: String
        if let data = try? JSONEncoder().encode(self),
           let json = String(data: data, encoding: .utf8) {
            payload = json
        } else {
            payload = "{}"
        }
        return "\(Self.openTag)\(payload)\(Self.closeTag)"
    }
}
