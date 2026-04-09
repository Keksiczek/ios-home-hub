import Foundation

/// Deterministic in-process runtime used by SwiftUI previews and
/// unit tests. Streams a canned response token by token so previews
/// look like the real thing without ever loading a model file.
final class MockLocalRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "mock"
    private(set) var loadedModel: LocalModel?

    func load(model: LocalModel) async throws {
        try? await Task.sleep(nanoseconds: 200_000_000)
        loadedModel = model
    }

    func unload() async {
        loadedModel = nil
    }

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let userTurn = prompt.messages.last(where: { $0.role == .user })?.content ?? ""
                let canned = MockLocalRuntime.cannedResponse(for: userTurn)
                var emitted = 0
                let started = Date()

                for piece in MockLocalRuntime.tokenize(canned) {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 35_000_000)
                    continuation.yield(.token(piece))
                    emitted += 1
                }

                let elapsed = Date().timeIntervalSince(started)
                continuation.yield(.finished(
                    reason: Task.isCancelled ? .cancelled : .stop,
                    stats: RuntimeStats(
                        tokensGenerated: emitted,
                        tokensPerSecond: Double(emitted) / max(elapsed, 0.001),
                        totalDurationMs: Int(elapsed * 1000)
                    )
                ))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func cannedResponse(for input: String) -> String {
        if input.lowercased().contains("hello") || input.isEmpty {
            return "Hi there. I'm running entirely on this device. Ask me anything and I'll do my best to help."
        }
        return "Got it. Here's how I'd think about that: first, the immediate goal — then the constraints — then a small first step you can take today. Let me know which part you want to dig into."
    }

    private static func tokenize(_ text: String) -> [String] {
        // Pseudo-tokens by word, preserving spaces, for streaming feel.
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        return parts.enumerated().map { idx, part in
            idx == parts.count - 1 ? String(part) : String(part) + " "
        }
    }
}
