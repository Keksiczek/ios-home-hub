import Foundation

/// Stripping of chat-template control tokens that sometimes leak past the
/// runtime's `llama_token_is_control` filter (for example when a small
/// model emits the token's *text form* — `<start_of_turn>` — rather than
/// the actual control-token ID).
///
/// Scope is deliberately narrow:
///   * It only removes well-known envelope markers from Gemma / Llama /
///     ChatML / common end-of-sequence tags.
///   * It never touches user markdown, code blocks, or the `<tool_call>` /
///     `<Observation>` envelopes (those are structural and must round-trip).
///   * It collapses the whitespace left behind so bubbles don't render
///     stray blank lines where a stripped tag used to sit.
///
/// Used by the chat UI when rendering assistant content and by the
/// conversation exporter, but NEVER by the streaming hot path itself —
/// the raw text stays in `Message.content` so diagnostics and tests can
/// still see what the model emitted verbatim.
enum ChatTextSanitizer {

    /// Tokens to strip. Kept as a static list instead of a regex alternation
    /// so adding a new family is a one-line change and the compiler can
    /// catch typos. All comparisons are case-sensitive (these really are
    /// emitted in lower / specific case by the respective chat templates).
    private static let controlTokens: [String] = [
        // Gemma 2 / Gemma 3
        "<start_of_turn>", "<end_of_turn>",
        // Llama 3
        "<|begin_of_text|>", "<|end_of_text|>",
        "<|start_header_id|>", "<|end_header_id|>",
        "<|eot_id|>",
        // ChatML / Phi-3 / Qwen
        "<|im_start|>", "<|im_end|>",
        // Classic EOS variants
        "</s>", "<s>",
        // Plain-text leaks (some small models serialise the tag name
        // without angle brackets when the raw control ID is suppressed).
        "startofturn", "endofturn", "eotid"
    ]

    /// Returns `content` with all known control tokens removed and any
    /// leftover triple-newline / leading-trailing whitespace collapsed.
    static func strip(_ content: String) -> String {
        guard !content.isEmpty else { return content }

        var cleaned = content
        for token in controlTokens {
            // `replacingOccurrences` is sufficient — tokens are fixed strings.
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }

        // Collapse any run of 3+ newlines to exactly two so stripped tags
        // don't leave visible gaps. A regex here is fine — the input is
        // at most a single assistant turn.
        if let regex = try? NSRegularExpression(pattern: "\\n{3,}") {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: range,
                withTemplate: "\n\n"
            )
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
