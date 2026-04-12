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

    // MARK: - GPU strategy

    enum GPULayers: Sendable {
        /// CPU-only inference. Safe everywhere including the Simulator.
        case none
        /// Offload all layers to GPU — optimal on all Metal-capable devices.
        case maximum
        /// Offload exactly `n` transformer layers to GPU.
        case layers(Int)

        fileprivate var count: Int32 {
            switch self {
            case .none:          return 0
            case .maximum:       return 999
            case .layers(let n): return Int32(n)
            }
        }
    }

#if HOMEHUB_REAL_RUNTIME

    // MARK: - Real llama.cpp implementation

    private let contextPtr: OpaquePointer   // llama_context *
    private let modelPtr: OpaquePointer     // llama_model *

    private init(context: OpaquePointer, model: OpaquePointer) {
        self.contextPtr = context
        self.modelPtr = model
    }

    // MARK: - One-time backend init

    private static let backendInitOnce: Void = {
        llama_backend_init()
    }()

    // MARK: - Factory

    static func load(
        modelPath: String,
        contextLength: Int,
        gpuLayers: GPULayers
    ) throws -> LlamaContextHandle {
        _ = backendInitOnce

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpuLayers.count

        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw RuntimeError.incompatibleModel(
                "llama_model_load_from_file returned nil for \(modelPath). " +
                "The file may be corrupt, use an unsupported quantisation, or have an invalid GGUF header."
            )
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx    = UInt32(contextLength)
        ctxParams.n_batch  = 512
        ctxParams.n_ubatch = 512
        ctxParams.flash_attn = true

        guard let ctx = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            throw RuntimeError.outOfMemory
        }

        return LlamaContextHandle(context: ctx, model: model)
    }

    // MARK: - Generation

    func stream(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        stopSequences: [String]
    ) throws -> AsyncThrowingStream<String, Error> {
        let ctx = contextPtr
        let model = modelPtr

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    // --- 1. Tokenise ---
                    let promptBytes = Array(prompt.utf8CString)
                    let maxTokenCount = promptBytes.count + 64
                    var tokens = [llama_token](repeating: 0, count: maxTokenCount)
                    let nTokens = tokens.withUnsafeMutableBufferPointer { buf in
                        llama_tokenize(
                            model,
                            promptBytes, Int32(promptBytes.count - 1), // exclude null terminator
                            buf.baseAddress!, Int32(maxTokenCount),
                            true,  // add_special (BOS)
                            false  // parse_special
                        )
                    }

                    guard nTokens > 0 else {
                        continuation.finish(throwing: RuntimeError.underlying("Tokenisation failed"))
                        return
                    }

                    let promptTokens = Array(tokens.prefix(Int(nTokens)))

                    // --- 2. Clear KV cache ---
                    llama_kv_cache_clear(ctx)

                    // --- 3. Evaluate prompt in batches ---
                    let batchSize = 512
                    var pos: Int32 = 0
                    for batchStart in stride(from: 0, to: promptTokens.count, by: batchSize) {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        let batchEnd = min(batchStart + batchSize, promptTokens.count)
                        let batchSlice = Array(promptTokens[batchStart..<batchEnd])
                        let n = Int32(batchSlice.count)

                        let batch = batchSlice.withUnsafeBufferPointer { buf in
                            llama_batch_get_one(UnsafeMutablePointer(mutating: buf.baseAddress!), n)
                        }

                        let status = llama_decode(ctx, batch)
                        if status != 0 {
                            continuation.finish(throwing: RuntimeError.underlying(
                                "llama_decode failed during prompt evaluation (status: \(status))"
                            ))
                            return
                        }
                        pos += n
                    }

                    // --- 4. Set up sampler chain ---
                    let samplerParams = llama_sampler_chain_default_params()
                    guard let sampler = llama_sampler_chain_init(samplerParams) else {
                        continuation.finish(throwing: RuntimeError.underlying("Failed to init sampler chain"))
                        return
                    }
                    defer { llama_sampler_free(sampler) }

                    llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
                    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(topP, 1))
                    llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

                    // --- 5. Generation loop ---
                    var stopBuffer = ""
                    let maxStopLen = stopSequences.map(\.count).max() ?? 0
                    let eosToken = llama_vocab_eos(llama_model_get_vocab(model))

                    for _ in 0..<maxTokens {
                        if Task.isCancelled {
                            llama_kv_cache_clear(ctx)
                            continuation.finish()
                            return
                        }

                        let newToken = llama_sampler_sample(sampler, ctx, -1)

                        if newToken == eosToken {
                            // Flush any buffered text
                            if !stopBuffer.isEmpty {
                                continuation.yield(stopBuffer)
                            }
                            continuation.finish()
                            return
                        }

                        // Convert token to text
                        var pieceBuffer = [CChar](repeating: 0, count: 256)
                        let pieceLen = llama_token_to_piece(
                            model, newToken,
                            &pieceBuffer, Int32(pieceBuffer.count),
                            0,     // lstrip
                            false  // special
                        )

                        guard pieceLen > 0 else { continue }

                        let piece = String(
                            bytes: pieceBuffer.prefix(Int(pieceLen)).map { UInt8(bitPattern: $0) },
                            encoding: .utf8
                        ) ?? ""

                        // Stop sequence detection
                        if !stopSequences.isEmpty {
                            stopBuffer += piece
                            var matched = false
                            for seq in stopSequences {
                                if stopBuffer.contains(seq) {
                                    // Yield text before the stop sequence
                                    if let range = stopBuffer.range(of: seq) {
                                        let before = String(stopBuffer[stopBuffer.startIndex..<range.lowerBound])
                                        if !before.isEmpty {
                                            continuation.yield(before)
                                        }
                                    }
                                    continuation.finish()
                                    return
                                }
                            }
                            // Flush safe prefix (keep only last maxStopLen chars)
                            if stopBuffer.count > maxStopLen {
                                let flushEnd = stopBuffer.index(stopBuffer.endIndex, offsetBy: -maxStopLen)
                                let toFlush = String(stopBuffer[stopBuffer.startIndex..<flushEnd])
                                continuation.yield(toFlush)
                                stopBuffer = String(stopBuffer[flushEnd...])
                            }
                        } else {
                            continuation.yield(piece)
                        }

                        // Prepare next decode
                        var nextTokenArr = [newToken]
                        let nextBatch = nextTokenArr.withUnsafeMutableBufferPointer { buf in
                            llama_batch_get_one(buf.baseAddress!, 1)
                        }
                        let decodeStatus = llama_decode(ctx, nextBatch)
                        if decodeStatus != 0 {
                            continuation.finish(throwing: RuntimeError.underlying(
                                "llama_decode failed during generation (status: \(decodeStatus))"
                            ))
                            return
                        }
                    }

                    // Flush remaining buffer
                    if !stopBuffer.isEmpty {
                        continuation.yield(stopBuffer)
                    }
                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Cleanup

    func close() {
        llama_free(contextPtr)
        llama_model_free(modelPtr)
    }

#else

    // MARK: - Stub implementation (development builds)

    static func load(
        modelPath: String,
        contextLength: Int,
        gpuLayers: GPULayers
    ) throws -> LlamaContextHandle {
        throw RuntimeError.underlying(
            "LlamaContextHandle.load is a stub – wire in the llama.cpp xcframework. " +
            "Set HOMEHUB_REAL_RUNTIME in Swift Active Compilation Conditions to enable the real runtime."
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
            continuation.finish(
                throwing: RuntimeError.underlying("LlamaContextHandle.stream stub")
            )
        }
    }

    func close() {
        // No-op in stub mode.
    }

#endif
}
