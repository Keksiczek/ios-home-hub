import Foundation

/// Renders a `RuntimePrompt` into the raw text format expected by the
/// model. v1 uses a single Llama 3 / Qwen-style chat template that
/// works for the recommended catalog. Per-model overrides can be
/// keyed off `LocalModel.family` later.
enum ChatTemplate {
    static func render(_ prompt: RuntimePrompt) -> String {
        var out = ""
        out += "<|im_start|>system\n\(prompt.systemPrompt)<|im_end|>\n"
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
}
