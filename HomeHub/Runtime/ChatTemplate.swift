import Foundation

/// Renders a `RuntimePrompt` into the raw text format expected by the model.
///
/// ## Family dispatch
/// | `family`   | Format              | Models                      |
/// |------------|---------------------|-----------------------------|
/// | `"Llama"`  | Llama 3 header      | Llama 3.x, Llama 3.1, 3.2   |
/// | anything else | ChatML (`<|im_start|>`) | Qwen 2.x, Phi 3.x      |
///
/// The family string comes from `LocalModel.family` and is passed in by
/// `LlamaCppRuntime` at generation time. Default (empty string) falls
/// through to ChatML so the mock runtime and tests work without changes.
enum ChatTemplate {

    static func render(_ prompt: RuntimePrompt, family: String = "") -> String {
        if family.lowercased() == "llama" {
            return renderLlama3(prompt)
        }
        return renderChatML(prompt)
    }

    // MARK: - ChatML  (Qwen 2.x, Phi 3.x)

    /// Format: `<|im_start|>{role}\n{content}<|im_end|>\n`
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

    /// Format: `<|begin_of_text|><|start_header_id|>{role}<|end_header_id|>\n\n{content}<|eot_id|>`
    ///
    /// Reference: https://llama.meta.com/docs/model-cards-and-prompt-formats/llama3_1
    private static func renderLlama3(_ prompt: RuntimePrompt) -> String {
        var out = "<|begin_of_text|>"

        // System turn
        out += "<|start_header_id|>system<|end_header_id|>\n\n"
        out += prompt.systemPrompt
        out += "<|eot_id|>"

        // Conversation turns
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

        // Open the next assistant turn — the model will complete from here
        out += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        return out
    }
}
