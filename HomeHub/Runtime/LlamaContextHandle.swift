import Foundation

/// Swift bridge to the llama.cpp C++ engine.
///
/// # Lifecycle
/// ```
/// let ctx = try LlamaContextHandle.load(modelPath:contextLength:gpuLayers:)
/// let stream = try ctx.stream(prompt:maxTokens:temperature:topP:stopSequences:)
/// for try await piece in stream { ... }
/// ctx.close()   // always call when done
/// ```
///
/// # Wiring the real implementation
/// 1. Add the llama.cpp xcframework (built with `cmake -DGGML_METAL=ON`)
///    as a binary target in `Package.swift` or directly into the Xcode
///    project under *Frameworks, Libraries, and Embedded Content*.
/// 2. Create a bridging header (or a separate `LlamaCppKit` SPM target)
///    that imports `llama.h`.
/// 3. Replace the bodies of `load`, `stream`, and `close` below with the
///    corresponding llama.cpp C-API calls:
///    - `load`   → `llama_load_model_from_file` + `llama_new_context_with_model`
///    - `stream` → `llama_decode` loop + `llama_token_to_piece` per token
///    - `close`  → `llama_free` + `llama_free_model`
///
/// # GPU layers
/// Pass `.maximum` on Metal-capable devices (iPhone 12+ / all Apple Silicon
/// iPads). Use `.none` in the iOS Simulator where Metal compute shaders are
/// unavailable. Use `.layers(n)` for partial GPU offload on memory-constrained
/// devices.
///
/// # Memory ownership
/// The C++ side owns the `llama_model` and `llama_context` pointers.
/// `LlamaContextHandle` holds an opaque reference and is the only Swift
/// object that may call `llama_free` / `llama_free_model`. The owning
/// `LlamaRuntimeActor` ensures `close()` is called exactly once.
struct LlamaContextHandle: @unchecked Sendable {

    // TODO: Store UnsafeMutableRawPointer to llama_context here when
    // the real xcframework is wired in. Keep the model pointer alongside
    // so close() can free both in the right order (context first, then model).
    //
    // Example:
    //   private let context: OpaquePointer   // llama_context *
    //   private let model:   OpaquePointer   // llama_model *

    // MARK: - GPU strategy

    enum GPULayers: Sendable {
        /// CPU-only inference. Safe everywhere including the Simulator.
        case none
        /// Offload all layers to GPU — optimal on all Metal-capable devices.
        case maximum
        /// Offload exactly `n` transformer layers to GPU.
        case layers(Int)

        /// Maps to the `n_gpu_layers` parameter expected by llama.cpp.
        fileprivate var count: Int32 {
            switch self {
            case .none:         return 0
            case .maximum:      return 999   // llama.cpp interprets large values as "all"
            case .layers(let n): return Int32(n)
            }
        }
    }

    // MARK: - Factory

    /// Loads a GGUF model from disk and prepares an inference context.
    ///
    /// This call is synchronous and blocks the calling thread until the
    /// model weights are mapped into memory. Run it from a background
    /// thread / actor task — `LlamaRuntimeActor.load` handles this.
    ///
    /// - Parameters:
    ///   - modelPath: Absolute path to a `.gguf` file inside the app sandbox.
    ///   - contextLength: KV-cache size in tokens. Match the model's advertised
    ///     context window.
    ///   - gpuLayers: Metal offload strategy (see ``GPULayers``).
    ///
    /// - Throws:
    ///   - `RuntimeError.incompatibleModel` — GGUF header unrecognised or
    ///     quantisation type unsupported by this build.
    ///   - `RuntimeError.outOfMemory` — model weights + KV cache exceed the
    ///     device's available unified memory.
    ///   - `RuntimeError.underlying` — unexpected llama.cpp error.
    static func load(
        modelPath: String,
        contextLength: Int,
        gpuLayers: GPULayers
    ) throws -> LlamaContextHandle {
        // TODO: Replace this block with real llama.cpp calls:
        //
        //   var modelParams = llama_model_default_params()
        //   modelParams.n_gpu_layers = gpuLayers.count
        //
        //   guard let model = llama_load_model_from_file(modelPath, modelParams) else {
        //       // llama.cpp returns nil on bad GGUF or unsupported quant
        //       throw RuntimeError.incompatibleModel(
        //           "llama_load_model_from_file returned nil for \(modelPath)"
        //       )
        //   }
        //
        //   var ctxParams = llama_context_default_params()
        //   ctxParams.n_ctx     = UInt32(contextLength)
        //   ctxParams.n_batch   = 512
        //   ctxParams.n_ubatch  = 512
        //   ctxParams.flash_attn = true  // Metal supports flash attention
        //
        //   guard let ctx = llama_new_context_with_model(model, ctxParams) else {
        //       llama_free_model(model)
        //       throw RuntimeError.outOfMemory
        //   }
        //
        //   return LlamaContextHandle(context: ctx, model: model)

        throw RuntimeError.underlying(
            "LlamaContextHandle.load is a stub – wire in the llama.cpp xcframework. " +
            "See the doc comment above for step-by-step instructions."
        )
    }

    // MARK: - Generation

    /// Streams decoded token pieces for `prompt`.
    ///
    /// Each yielded `String` is a BPE/SentencePiece *piece* (typically one
    /// to a few characters). The stream ends when the model emits EOS, when
    /// `maxTokens` is reached, or when a `stopSequence` is detected.
    /// Cancelling the consuming `Task` stops generation via `Task.isCancelled`.
    ///
    /// - Throws: `RuntimeError.underlying` on any llama.cpp sampling error.
    func stream(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        stopSequences: [String]
    ) throws -> AsyncThrowingStream<String, Error> {
        // TODO: Replace with real generation loop:
        //
        //   1. Tokenise: llama_tokenize(model, prompt, tokens, maxLen, addBos, special)
        //   2. Evaluate prompt: llama_decode(context, batch)
        //   3. For i in 0..<maxTokens:
        //      a. Sample: configure llama_sampler (temperature, top-p, repetition)
        //      b. token = llama_sampler_sample(sampler, context, -1)
        //      c. if token == llama_token_eos(model) { break }
        //      d. piece = llama_token_to_piece(model, token)
        //      e. Check stopSequences; if matched, break
        //      f. yield piece
        //      g. if Task.isCancelled { llama_kv_cache_clear(context); break }
        //   4. Clean up sampler

        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: RuntimeError.underlying("LlamaContextHandle.stream stub")
            )
        }
    }

    // MARK: - Cleanup

    /// Frees the llama_context and llama_model pointers.
    ///
    /// Must be called exactly once when this handle is no longer needed.
    /// `LlamaRuntimeActor` guarantees this via its `unload()` method.
    func close() {
        // TODO: llama_free(context); llama_free_model(model)
        // Order matters: free the context before the model.
    }
}
