import XCTest
@testable import HomeHub

/// Regression tests for `ChatTemplate.render`.
///
/// The primary contract these tests pin down is that **Gemma 3 / 3n have
/// no native system role**. Google's official chat template prepends the
/// system prompt to the first user turn with `\n\n` separator (same as
/// Gemma 2). A previous version of `renderGemma3` incorrectly emitted
/// `<start_of_turn>system…<end_of_turn>` — a token sequence Google never
/// trained the model on, manifesting as language drift, garbled tool-
/// call wrappers, and inconsistent output in the field.
///
/// If a future refactor accidentally reintroduces a system-role turn for
/// Gemma 3, these tests fail.
final class ChatTemplateTests: XCTestCase {

    // MARK: - Gemma 3 / 3n  (no native system role)

    func testGemma3PrependsSystemPromptToFirstUserTurn() {
        let prompt = RuntimePrompt(
            systemPrompt: "You are a helpful assistant.",
            messages: [RuntimeMessage(role: .user, content: "Hi")]
        )
        let rendered = ChatTemplate.render(prompt, family: "Gemma3n")

        // System content must appear INSIDE the first user turn, not in
        // its own `<start_of_turn>system…` block.
        XCTAssertTrue(rendered.contains("<start_of_turn>user\nYou are a helpful assistant.\n\nHi<end_of_turn>"),
                      "Gemma 3 system prompt must be prepended to first user turn:\n\(rendered)")
        XCTAssertFalse(rendered.contains("<start_of_turn>system"),
                       "Gemma 3 has no native system role — must not emit `<start_of_turn>system`:\n\(rendered)")
    }

    func testGemma3MultiTurnDoesNotRepeatSystemPrompt() {
        let prompt = RuntimePrompt(
            systemPrompt: "Be concise.",
            messages: [
                RuntimeMessage(role: .user, content: "Q1"),
                RuntimeMessage(role: .assistant, content: "A1"),
                RuntimeMessage(role: .user, content: "Q2")
            ]
        )
        let rendered = ChatTemplate.render(prompt, family: "Gemma3n")

        // System prompt appears exactly once — on the FIRST user turn only.
        let systemOccurrences = rendered.components(separatedBy: "Be concise.").count - 1
        XCTAssertEqual(systemOccurrences, 1,
                       "Gemma 3 must inject system prompt only once (on first user turn):\n\(rendered)")
        // The model turn for A1 is emitted correctly.
        XCTAssertTrue(rendered.contains("<start_of_turn>model\nA1<end_of_turn>"),
                      "Gemma 3 assistant turn uses `model` role:\n\(rendered)")
        // Final turn primes the model to respond.
        XCTAssertTrue(rendered.hasSuffix("<start_of_turn>model\n"),
                      "Gemma 3 must end with `<start_of_turn>model\\n`:\n\(rendered)")
    }

    func testGemma3DropsInlineSystemMessages() {
        // Inline `.system` messages have no representable form in
        // Gemma 3; they must be dropped silently, with the canonical
        // `prompt.systemPrompt` carrying the system context.
        let prompt = RuntimePrompt(
            systemPrompt: "Top-level system.",
            messages: [
                RuntimeMessage(role: .system, content: "INLINE SYSTEM"),
                RuntimeMessage(role: .user, content: "Hi")
            ]
        )
        let rendered = ChatTemplate.render(prompt, family: "Gemma3")

        XCTAssertFalse(rendered.contains("INLINE SYSTEM"),
                       "Gemma 3 must drop inline `.system` messages (no role token exists):\n\(rendered)")
        XCTAssertTrue(rendered.contains("Top-level system."),
                      "Top-level systemPrompt still surfaces on first user turn:\n\(rendered)")
    }

    func testGemma3FamilyAliases() {
        let prompt = RuntimePrompt(
            systemPrompt: "S",
            messages: [RuntimeMessage(role: .user, content: "U")]
        )
        // All three family strings must route to the Gemma 3 renderer.
        for family in ["Gemma3n", "gemma3n", "Gemma3", "gemma3", "Gemma", "gemma"] {
            let rendered = ChatTemplate.render(prompt, family: family)
            XCTAssertFalse(rendered.contains("<start_of_turn>system"),
                           "Family '\(family)' must use Gemma 3 envelope (no system role)")
            XCTAssertTrue(rendered.hasSuffix("<start_of_turn>model\n"),
                          "Family '\(family)' must end with model prime")
        }
    }

    // MARK: - Gemma 2  (no system role — same shape as Gemma 3)

    func testGemma2PrependsSystemPromptToFirstUserTurn() {
        let prompt = RuntimePrompt(
            systemPrompt: "Sys",
            messages: [RuntimeMessage(role: .user, content: "Hi")]
        )
        let rendered = ChatTemplate.render(prompt, family: "Gemma2")

        XCTAssertTrue(rendered.contains("<start_of_turn>user\nSys\n\nHi<end_of_turn>"),
                      "Gemma 2 system prompt must be prepended to first user turn:\n\(rendered)")
        XCTAssertFalse(rendered.contains("<start_of_turn>system"),
                       "Gemma 2 has no system role:\n\(rendered)")
    }
}
