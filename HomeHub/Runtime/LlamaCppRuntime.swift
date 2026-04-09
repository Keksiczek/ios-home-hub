import Foundation

/// V1 preferred local runtime, backed by `llama.cpp` compiled as an
/// xcframework with the Metal backend enabled.
///
/// In the real project, the actual GGML/llama.cpp Swift binding lives
/// in a separate SwiftPM target (e.g. `LlamaCppKit`) that vends a
/// concrete `LlamaContext`. This file integrates with it through the
/// `LlamaContextHandle` placeholder below: replace the body of
/// `LlamaContextHandle.load(...)` and `.stream(...)` with calls into
/// the binding.
///
/// Why llama.cpp for v1:
/// - mature GGUF support, fast iteration on quantization formats
/// - first-class Metal kernels for A18 / M-series
/// - works equally well on iPhone and iPad with the same binary
/// - large catalog of compatible quantized models (Llama 3.2 3B,
///   Phi 3.5 mini, Qwen 2.5 3B/7B, Mistral 7B, ...)
/// - small surface to bridge into Swift
///
/// Future: an `MLXRuntime` sibling can take over on M-series iPad
/// where MLX gives better throughput, while keeping iPhone on
/// llama.cpp. Both back the same `LocalLLMRuntime` protocol.
final class LlamaCppRuntime: LocalLLMRuntime, @unchecked Sendable {
    let identifier = "llama.cpp"

    private let lock = NSLock()
    private var _loadedModel: LocalModel?
    private var context: LlamaContextHandle?

    var loadedModel: LocalModel? {
        lock.lock(); defer { lock.unlock() }
        return _loadedModel
    }

    func load(model: LocalModel) async throws {
        guard case .installed(let url) = model.installState else {
            throw RuntimeError.modelNotInstalled
        }
        try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let ctx = try LlamaContextHandle.load(
                    modelPath: url.path,
                    contextLength: model.contextLength,
                    gpuLayers: .maximum
                )
                self.lock.lock()
                self.context?.close()
                self.context = ctx
                self._loadedModel = model
                self.lock.unlock()
            } catch {
                throw RuntimeError.underlying(error.localizedDescription)
            }
        }.value
    }

    func unload() async {
        await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.context?.close()
            self.context = nil
            self._loadedModel = nil
            self.lock.unlock()
        }.value
    }

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            let ctx: LlamaContextHandle? = {
                self.lock.lock(); defer { self.lock.unlock() }
                return self.context
            }()

            guard let ctx else {
                continuation.finish(throwing: RuntimeError.noModelLoaded)
                return
            }

            let task = Task.detached(priority: .userInitiated) {
                let renderedPrompt = ChatTemplate.render(prompt)
                let started = Date()
                var tokens = 0

                do {
                    let stream = try ctx.stream(
                        prompt: renderedPrompt,
                        maxTokens: parameters.maxTokens,
                        temperature: Float(parameters.temperature),
                        topP: Float(parameters.topP),
                        stopSequences: parameters.stopSequences
                    )

                    for try await piece in stream {
                        if Task.isCancelled {
                            continuation.yield(.finished(
                                reason: .cancelled,
                                stats: RuntimeStats(
                                    tokensGenerated: tokens,
                                    tokensPerSecond: 0,
                                    totalDurationMs: Int(Date().timeIntervalSince(started) * 1000)
                                )
                            ))
                            continuation.finish()
                            return
                        }
                        tokens += 1
                        continuation.yield(.token(piece))
                    }

                    let elapsed = Date().timeIntervalSince(started)
                    continuation.yield(.finished(
                        reason: .stop,
                        stats: RuntimeStats(
                            tokensGenerated: tokens,
                            tokensPerSecond: Double(tokens) / max(elapsed, 0.001),
                            totalDurationMs: Int(elapsed * 1000)
                        )
                    ))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// MARK: - Bridge placeholder

/// Placeholder for the actual llama.cpp Swift binding.
///
/// In a real build this is replaced by a concrete type vended by a
/// `LlamaCppKit` package that links the llama.cpp xcframework. The
/// public surface should stay this small so the rest of the app
/// never has to know GGML exists.
struct LlamaContextHandle: @unchecked Sendable {
    enum GPULayers: Sendable {
        case none
        case maximum
        case layers(Int)
    }

    static func load(
        modelPath: String,
        contextLength: Int,
        gpuLayers: GPULayers
    ) throws -> LlamaContextHandle {
        // Future: bridge into llama.cpp.
        throw RuntimeError.underlying(
            "LlamaContextHandle.load is a stub. Wire in the llama.cpp xcframework."
        )
    }

    func stream(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        stopSequences: [String]
    ) throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: RuntimeError.underlying("LlamaContextHandle.stream stub"))
        }
    }

    func close() { /* future: free llama_context */ }
}
