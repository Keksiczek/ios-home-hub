import Foundation

/// Stripping of chat-template control tokens that sometimes leak past the
/// runtime's tokenizer-level control filter (for example when a small model
/// emits the token's *text form* — `<start_of_turn>` — rather than the
/// actual control-token ID). Affects both backends: MLX (via the
/// `swift-transformers` tokenizer bridge) and llama.cpp (via
/// `llama_token_is_control`) leak the same surface forms when the model
/// is undertrained on the chat template.
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
        "<bos>", "<eos>",
        // Llama 3
        "<|begin_of_text|>", "<|end_of_text|>",
        "<|start_header_id|>", "<|end_header_id|>",
        "<|eot_id|>", "<|eom_id|>", "<|finetune_right_pad_id|>",
        "<|python_tag|>",
        // ChatML / Phi-3 / Qwen / Qwen2.5
        "<|im_start|>", "<|im_end|>",
        "<|endoftext|>",
        // Phi-4 / Phi-3 mini
        "<|user|>", "<|assistant|>", "<|system|>", "<|end|>", "<|tool|>",
        // Mistral / Mixtral instruct envelopes — `[INST]` / `[/INST]` are
        // structural for the wire format but should never reach the user.
        "[INST]", "[/INST]",
        // Classic EOS variants
        "</s>", "<s>", "<pad>", "<unk>",
        // Plain-text leaks (some small models serialise the tag name
        // without angle brackets when the raw control ID is suppressed).
        "startofturn", "endofturn", "eotid",
        "<|im_sep|>"
    ]

    /// Per-line trims (full lines that match are deleted entirely).
    /// Catches the common "the model echoes the role header on its own line"
    /// failure mode without corrupting normal content. Applied AFTER token
    /// stripping so e.g. `<|im_start|>assistant\n` collapses cleanly.
    private static let leadingRoleHeaders: [String] = [
        "assistant", "user", "system", "model"
    ]

    /// Returns `content` with all known control tokens removed and any
    /// leftover triple-newline / leading-trailing whitespace collapsed.
    static func strip(_ content: String) -> String {
        guard !content.isEmpty else { return content }

        var cleaned = content
        // Use a single regex pass to strip all control tokens. This is significantly 
        // faster than 30+ sequential `replacingOccurrences` calls, especially 
        // during streaming when this is called frequently on growing strings.
        if let regex = tokensRegex {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }

        // Drop the U+FFFD replacement character. It only ever appears when
        // the tokenizer emitted a multi-byte UTF-8 sequence split across two
        // pieces, and showing a black-diamond `?` to the user is worse than
        // dropping it. Both runtimes (MLX via the swift-transformers
        // tokenizer bridge, llama.cpp via the LlamaContextHandle byte
        // buffer) try to recover, but historical messages and any future
        // regression in either buffer surface here as a safety net.
        cleaned = cleaned.replacingOccurrences(of: "\u{FFFD}", with: "")

        // Drop NULs and other C0 control characters except tab/newline.
        // These leak from broken tokenizers on quantized models and would
        // otherwise render as invisible glitches in the chat bubble.
        var rebuilt = ""
        rebuilt.reserveCapacity(cleaned.utf8.count)
        for scalar in cleaned.unicodeScalars {
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D || (v >= 0x20 && v != 0x7F) {
                rebuilt.unicodeScalars.append(scalar)
            }
        }
        cleaned = rebuilt

        // Strip stray leading role headers on their own line. Some small
        // chat models echo `assistant\n` at the very start of their turn
        // even when the chat template should have suppressed that token.
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces).lowercased()
            if leadingRoleHeaders.contains(trimmed) {
                cleaned = lines.dropFirst().joined(separator: "\n")
            }
        }

        // Strip *empty* tool_call / Observation envelopes. The model
        // sometimes opens and immediately closes the tag (e.g.
        // `<tool_call></tool_call>` or `<tool_call> </tool_call>`)
        // when its tool-call grammar misfires; downstream parsing
        // ignores the empty envelope but it still leaks into the
        // bubble as visible junk. Non-empty envelopes round-trip
        // unchanged — tool-result rendering depends on them.
        //
        // Fast-path: `<` and `[` literal scan bails before paying for
        // 6 regex matches on streaming intermediate states that don't
        // contain any envelope candidates (~99% of streaming token
        // batches before the model emits its first tool tag).
        if cleaned.contains("<") || cleaned.contains("[TOOL_CALLS]") {
            for regex in emptyEnvelopeRegexes {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: range,
                    withTemplate: ""
                )
            }
        }

        // Collapse any run of 3+ newlines to exactly two so stripped tags
        // don't leave visible gaps.
        if let regex = collapseNewlinesRegex {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: range,
                withTemplate: "\n\n"
            )
        }

        // Normalise the trailing-whitespace-on-every-line artifact some
        // models emit. Cheap to do; cleans up Markdown rendering.
        if let regex = trailingWhitespaceRegex {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: range,
                withTemplate: "\n"
            )
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Static, pre-compiled regex set for the empty-envelope strip.
    /// `ChatTextSanitizer.strip` runs on every `MessageBubbleView` body
    /// evaluation (~10× per second during streaming × N visible
    /// bubbles). Compiling six regexes per call was a measurable hot
    /// spot — pre-compile and freeze at process start.
    private static let emptyEnvelopeRegexes: [NSRegularExpression] = {
        let patterns = [
            "<tool_call>\\s*</tool_call>",
            "<function_call>\\s*</function_call>",
            "<function>\\s*</function>",
            "<tool>\\s*</tool>",
            "\\[TOOL_CALLS\\]\\s*\\[/TOOL_CALLS\\]",
            "<Observation>\\s*</Observation>"
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    private static let collapseNewlinesRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\n{3,}")
    }()

    private static let trailingWhitespaceRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "[ \\t]+\\n")
    }()

    /// Pre-compiled regex for all control tokens.
    private static let tokensRegex: NSRegularExpression? = {
        let pattern = controlTokens
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern)
    }()
}
