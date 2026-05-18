import Foundation

/// Renders a `RuntimePrompt` into the raw text format expected by the model.
///
/// ## Family dispatch
/// | `family`   | Format                        | Models                        |
/// |------------|-------------------------------|-------------------------------|
/// | `"Llama"`  | Llama 3 header tokens         | Llama 3.x, 3.1, 3.2           |
/// | `"Gemma3"` | Gemma 3 `<start_of_turn>`     | Gemma 3 4B / 12B              |
/// | `"Gemma2"` | Gemma 2 `<start_of_turn>`     | Gemma 2 2B / 9B (no sys role) |
/// | anything else | ChatML `<\|im_start\|>`    | Qwen 2.x, Phi 3.x             |
///
/// `family` comes from `LocalModel.family`. `LlamaCppRuntime` consumes the
/// rendered text directly; `MLXRuntime` lets `MLXLLM.ChatSession` apply the
/// model's stored Jinja chat template instead and only falls back to this
/// when the template is missing. An empty `family` value falls through to
/// ChatML so the mock runtime and tests work without changes.
enum ChatTemplate {

    /// Source of the chat template chosen for a render call. Surfaced in
    /// logs / DeveloperDiagnostics so multi-turn issues can be traced to
    /// the family selection step rather than the runtime itself.
    enum Source: Equatable {
        /// `model.family` from the curated catalog selected the family.
        case catalogFamily(String)
        /// `metadata.architecture` from the GGUF header overrode the catalog.
        /// Carries the architecture key (e.g. "llama", "qwen2", "gemma") that
        /// drove the dispatch.
        case ggufArchitecture(String)
        /// No usable family — fell back to the ChatML default.
        case chatMLFallback
    }

    static func render(_ prompt: RuntimePrompt, family: String = "") -> String {
        render(prompt, family: family, metadata: nil).rendered
    }

    /// Extended render path that consults GGUF header metadata before
    /// falling back to the catalog `family` string. Returns both the
    /// rendered text and the `Source` so callers can log which path was
    /// taken without re-deriving the answer.
    ///
    /// **Why architecture wins over family**: the catalog `family` field
    /// is a human-curated string that can drift from reality (e.g. a
    /// "Llama" entry that actually points at a Qwen-2.5 GGUF). The GGUF
    /// `general.architecture` value is written by the model author and
    /// is the authoritative identifier of which template the model
    /// expects. We still keep `family` as a fallback because not every
    /// GGUF ships metadata and the MLX path doesn't go through here at all.
    static func render(
        _ prompt: RuntimePrompt,
        family: String,
        metadata: GGUFModelMetadata?
    ) -> (rendered: String, source: Source) {
        if let arch = metadata?.architecture?.lowercased(), !arch.isEmpty {
            let rendered: String
            switch arch {
            case "llama":           rendered = renderLlama3(prompt)
            // Gemma 3n shares the surface `<start_of_turn>` envelope with
            // Gemma 3 — only the model's internal MatFormer routing
            // differs. Rendering Gemma 3n with the Gemma 3 template
            // gives the model the exact prefix structure it was
            // pre-trained on. Without this case the family-string
            // "Gemma3n" used to fall through to ChatML, which the
            // model then treated as free-form text and replied with
            // mixed-language nonsense.
            case "gemma3n", "gemma3", "gemma":
                rendered = renderGemma3(prompt)
            case "gemma2":          rendered = renderGemma2(prompt)
            case "qwen2", "qwen3", "phi3", "phi2":
                rendered = renderChatML(prompt)
            default:
                // Unknown architecture — still record the value we saw so
                // the diagnostics surface can explain *why* we picked
                // ChatML over the catalog hint.
                return (renderChatML(prompt), .ggufArchitecture(arch))
            }
            return (rendered, .ggufArchitecture(arch))
        }
        let key = family.lowercased()
        let rendered: String
        switch key {
        case "llama":   rendered = renderLlama3(prompt)
        // Mirror the architecture-side fix: catalog family "Gemma3n"
        // should resolve to the Gemma 3 envelope, not ChatML.
        case "gemma3n", "gemma3":
            rendered = renderGemma3(prompt)
        case "gemma2":  rendered = renderGemma2(prompt)
        default:
            return (renderChatML(prompt), key.isEmpty ? .chatMLFallback : .catalogFamily(key))
        }
        return (rendered, .catalogFamily(key))
    }

    // MARK: - ChatML  (Qwen 2.x, Phi 3.x)

    /// `<|im_start|>{role}\n{content}<|im_end|>\n`
    private static func renderChatML(_ prompt: RuntimePrompt) -> String {
        var out = "<|im_start|>system\n\(prompt.systemPrompt)<|im_end|>\n"
        for msg in prompt.messages {
            switch msg.role {
            case .system:
                out += "<|im_start|>system\n\(msg.content)<|im_end|>\n"
            case .user:
                out += "<|im_start|>user\n\(msg.content)<|im_end|>\n"
            case .assistant:
                out += "<|im_start|>assistant\n\(msg.content)<|im_end|>\n"
            }
        }
        out += "<|im_start|>assistant\n"
        return out
    }

    // MARK: - Llama 3  (Meta)

    /// `<|begin_of_text|><|start_header_id|>{role}<|end_header_id|>\n\n{content}<|eot_id|>`
    ///
    /// Reference: https://llama.meta.com/docs/model-cards-and-prompt-formats/llama3_1
    private static func renderLlama3(_ prompt: RuntimePrompt) -> String {
        var out = "<|begin_of_text|>"
        out += "<|start_header_id|>system<|end_header_id|>\n\n"
        out += prompt.systemPrompt
        out += "<|eot_id|>"
        for msg in prompt.messages {
            let header: String
            switch msg.role {
            case .system:    header = "system"
            case .user:      header = "user"
            case .assistant: header = "assistant"
            }
            out += "<|start_header_id|>\(header)<|end_header_id|>\n\n"
            out += msg.content
            out += "<|eot_id|>"
        }
        out += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        return out
    }

    // MARK: - Gemma 3  (Google, supports system role)

    /// `<bos><start_of_turn>system\n{sys}<end_of_turn>\n<start_of_turn>user\n…`
    ///
    /// Gemma 3 natively supports a `system` turn before the first user message.
    private static func renderGemma3(_ prompt: RuntimePrompt) -> String {
        var out = "<bos>"
        if !prompt.systemPrompt.isEmpty {
            out += "<start_of_turn>system\n\(prompt.systemPrompt)<end_of_turn>\n"
        }
        for msg in prompt.messages {
            switch msg.role {
            case .system:
                out += "<start_of_turn>system\n\(msg.content)<end_of_turn>\n"
            case .user:
                out += "<start_of_turn>user\n\(msg.content)<end_of_turn>\n"
            case .assistant:
                out += "<start_of_turn>model\n\(msg.content)<end_of_turn>\n"
            }
        }
        out += "<start_of_turn>model\n"
        return out
    }

    // MARK: - Gemma 2  (Google, no dedicated system role)

    /// Gemma 2 has no system role token. The system prompt is prepended to the
    /// first user turn, separated by a blank line, which is the standard
    /// workaround recommended by Google.
    private static func renderGemma2(_ prompt: RuntimePrompt) -> String {
        var out = "<bos>"
        var systemPrepended = false
        for msg in prompt.messages {
            switch msg.role {
            case .user:
                out += "<start_of_turn>user\n"
                if !systemPrepended && !prompt.systemPrompt.isEmpty {
                    out += prompt.systemPrompt + "\n\n"
                    systemPrepended = true
                }
                out += msg.content + "<end_of_turn>\n"
            case .assistant:
                out += "<start_of_turn>model\n\(msg.content)<end_of_turn>\n"
            case .system:
                // Inline .system messages are not representable in Gemma 2 —
                // they are silently dropped (system context belongs in the
                // top-level systemPrompt, injected above the first user turn).
                break
            }
        }
        out += "<start_of_turn>model\n"
        return out
    }
}
