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

    // MARK: - llama.cpp implementation

    private let contextPtr: OpaquePointer   // llama_context *
    private let modelPtr: OpaquePointer     // llama_model *
    private let contextLength: Int

    private init(context: OpaquePointer, model: OpaquePointer, contextLength: Int) {
        self.contextPtr = context
        self.modelPtr = model
        self.contextLength = contextLength
    }

    // MARK: - One-time backend init

    private static let backendInitOnce: Void = {
        llama_backend_init()
    }()

    // MARK: - Factory

    static func load(
        modelPath: String,
        contextLength: Int,
        gpuLayers: GPULayers,
        capabilities: ModelCapabilityProfile = .default
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

        // All model-specific parameters come from the resolved capability profile
        // rather than ad-hoc conditionals. See ModelCapabilityProfile.swift.
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx      = UInt32(contextLength)
        ctxParams.n_batch    = 512                             // keep large for prompt eval
        ctxParams.n_ubatch   = UInt32(capabilities.nUBatch)   // smaller for generation TTFT
        //ctxParams.flash_attn = capabilities.supportsFlashAttention

        guard let ctx = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            throw RuntimeError.outOfMemory
        }

        return LlamaContextHandle(context: ctx, model: model, contextLength: contextLength)
    }

    // MARK: - Generation

    func stream(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        stopSequences: [String],
        topK: Int32 = 40,
        minP: Float = 0.05,
        repeatPenalty: Float = 1.1,
        repeatPenaltyLastN: Int32 = 64,
        frequencyPenalty: Float = 0.0,
        presencePenalty: Float = 0.0,
        cachedTokens: [Int32] = [],
        cacheBox: StreamCacheBox? = nil
    ) throws -> AsyncThrowingStream<String, Error> {
        let ctx = contextPtr
        let model = modelPtr
        let n_ctx = contextLength

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    // --- 1. Tokenise ---
                    let promptBytes = Array(prompt.utf8CString)
                    let maxTokenCount = promptBytes.count + 64
                    var tokens = [llama_token](repeating: 0, count: maxTokenCount)
                    let nTokens = tokens.withUnsafeMutableBufferPointer { buf in
                        llama_tokenize(
                            llama_model_get_vocab(model),
                            promptBytes, Int32(promptBytes.count - 1), // exclude null terminator
                            buf.baseAddress!, Int32(maxTokenCount),
                            true,  // add_special (BOS)
                            false  // parse_special
                        )
                    }

                    guard nTokens > 0 else {
                        cacheBox?.finalPromptTokens = []
                        continuation.finish(throwing: RuntimeError.underlying("Tokenisation failed"))
                        return
                    }

                    let promptTokens = Array(tokens.prefix(Int(nTokens)))

                    // --- 2. Context-length guard ---
                    // Refuse to evaluate when the prompt alone already exceeds 90% of
                    // n_ctx. Without this guard the decode would silently truncate or
                    // crash. The PromptAssemblyService's history-token-budget (FIX 3)
                    // is the first line of defence; this is the belt-and-braces check
                    // at the bridge boundary.
                    let ctxBudget = Int(Double(n_ctx) * 0.9)
                    guard promptTokens.count <= ctxBudget else {
                        cacheBox?.finalPromptTokens = []
                        continuation.finish(throwing: RuntimeError.underlying(
                            "Prompt too large for context window: \(promptTokens.count) tokens " +
                            "exceeds safe budget of \(ctxBudget) (n_ctx = \(n_ctx)). " +
                            "Trim the conversation history or increase the model's context length."
                        ))
                        return
                    }

                    // --- 2b. KV-cache reuse or clear ---
                    // Compute how many leading tokens are already resident in the KV
                    // cache from the previous turn. If the reusable prefix covers at
                    // least 50% of the new prompt we skip llama_kv_cache_clear and
                    // begin prompt evaluation at prefixLen — those tokens are already
                    // decoded and their K/V activations are still valid.
                    //
                    // llama_batch_get_one with pos=nullptr auto-continues from the
                    // current KV cache position, so starting at prefixLen is correct
                    // without any llama_kv_cache_seq_shift calls.
                    //
                    // If the prefix is too short (first turn, different conversation,
                    // or regeneration with a different system prompt) we clear and
                    // re-evaluate the whole prompt as before.
                    var prefixLen = 0
                    if !cachedTokens.isEmpty {
                        var i = 0
                        while i < cachedTokens.count && i < promptTokens.count
                                && cachedTokens[i] == promptTokens[i] { i += 1 }
                        let ratio = Double(i) / Double(promptTokens.count)
                        if ratio >= ConversationRuntimeSession.minReuseRatio {
                            prefixLen = i
                        }
                    }

                    if prefixLen == 0 {
                        llama_memory_clear(llama_get_memory(ctx), false)
                    }

                    // --- 3. Evaluate prompt in batches (skip already-cached prefix) ---
                    let batchSize = 512
                    for batchStart in stride(from: prefixLen, to: promptTokens.count, by: batchSize) {
                        if Task.isCancelled {
                            cacheBox?.finalPromptTokens = promptTokens
                            continuation.finish()
                            return
                        }

                        let batchEnd = min(batchStart + batchSize, promptTokens.count)
                        let batchSlice = Array(promptTokens[batchStart..<batchEnd])

                        let batch = batchSlice.withUnsafeBufferPointer { buf in
                            llama_batch_get_one(UnsafeMutablePointer(mutating: buf.baseAddress!), Int32(batchSlice.count))
                        }

                        let status = llama_decode(ctx, batch)
                        if status != 0 {
                            cacheBox?.finalPromptTokens = promptTokens
                            continuation.finish(throwing: RuntimeError.underlying(
                                "llama_decode failed during prompt evaluation (status: \(status))"
                            ))
                            return
                        }
                    }

                    // --- 4. Set up sampler chain ---
                    //
                    // Order matters. llama.cpp pipes logits through samplers in
                    // chain order, so the canonical small-model recipe is:
                    //   penalties → top-k → top-p → min-p → temperature → dist
                    //
                    // The penalty + min-p step is what fixes most of the
                    // "garbage characters / Czech word salad / endless
                    // repetition" complaints on 2–4B GGUFs. min-p discards the
                    // long tail of low-probability tokens *before* temperature
                    // softens the distribution, so a hot temperature can no
                    // longer reach into pure noise. The repeat penalty stops
                    // the model from looping on a single phrase, which is the
                    // single most common failure mode of small instruct models.
                    guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
                        cacheBox?.finalPromptTokens = promptTokens
                        continuation.finish(throwing: RuntimeError.underlying("Failed to init sampler chain"))
                        return
                    }
                    defer { llama_sampler_free(sampler) }

                    // Repetition / frequency / presence penalties.
                    // `repeatPenaltyLastN <= 0` or `repeatPenalty == 1.0` makes
                    // it a no-op so we don't pay the cost when the user explicitly
                    // disables it (memoryExtraction mode does this for JSON output).
                    if repeatPenaltyLastN > 0 && repeatPenalty != 1.0 {
                        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
                            repeatPenaltyLastN,
                            repeatPenalty,
                            frequencyPenalty,
                            presencePenalty
                        ))
                    }
                    if topK > 0 {
                        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(topK))
                    }
                    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(topP, 1))
                    if minP > 0 {
                        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(minP, 1))
                    }
                    llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
                    llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

                    // --- 5. Generation loop ---
                    var stopBuffer = ""
                    let maxStopLen = stopSequences.map(\.count).max() ?? 0
                    let eosToken = llama_vocab_eos(llama_model_get_vocab(model))

                    // Holds bytes from a token whose UTF-8 sequence was cut
                    // mid-codepoint (very common for non-ASCII scripts —
                    // Czech diacritics, emoji, CJK). Without this buffer the
                    // streaming path would call `String(decoding:as: UTF8.self)`
                    // on a half-character and substitute U+FFFD, producing
                    // the "garbage characters" the user complained about.
                    // Drained whenever the buffer becomes a valid UTF-8 prefix.
                    var pendingBytes: [UInt8] = []

                    for _ in 0..<maxTokens {
                        if Task.isCancelled {
                            // Don't clear the KV cache — the prefix is still valid
                            // and can be reused on the next turn for the same conversation.
                            cacheBox?.finalPromptTokens = promptTokens
                            continuation.finish()
                            return
                        }

                        let newToken = llama_sampler_sample(sampler, ctx, -1)

                        if newToken == eosToken {
                            // Flush any leftover bytes from an incomplete UTF-8
                            // sequence. If they're still invalid by EOS the
                            // sanitizer will strip the substituted U+FFFD at
                            // render time — losing nothing the user cares about.
                            if !pendingBytes.isEmpty {
                                stopBuffer += String(decoding: pendingBytes, as: UTF8.self)
                                pendingBytes = []
                            }
                            if !stopBuffer.isEmpty { continuation.yield(stopBuffer) }
                            cacheBox?.finalPromptTokens = promptTokens
                            continuation.finish()
                            return
                        }

                        // Convert token to text
                        var pieceBuffer = [CChar](repeating: 0, count: 4096)
                        var pieceLen = llama_token_to_piece(llama_model_get_vocab(model), newToken,
                            &pieceBuffer, Int32(pieceBuffer.count),
                            0,     // lstrip
                            false  // special
                        )

                        if pieceLen < 0 {
                            let needed = Int(-pieceLen)
                            pieceBuffer = [CChar](repeating: 0, count: max(needed, 4096))
                            pieceLen = llama_token_to_piece(llama_model_get_vocab(model), newToken,
                                &pieceBuffer, Int32(pieceBuffer.count),
                                0,
                                false
                            )
                        }

                        guard pieceLen > 0 else { continue }

                        // Append the new bytes to whatever was left over from a
                        // previous token that ended mid-codepoint, then peel off
                        // the longest valid UTF-8 prefix. The remainder (an
                        // incomplete trailing sequence, if any) waits for the
                        // next token. No bytes are ever discarded, so non-ASCII
                        // scripts stream losslessly.
                        let newBytes = pieceBuffer.prefix(Int(pieceLen)).map { UInt8(bitPattern: $0) }
                        pendingBytes.append(contentsOf: newBytes)
                        let (piece, leftover) = Self.drainValidUTF8Prefix(from: pendingBytes)
                        pendingBytes = leftover

                        // Nothing to yield this round (still buffering a partial
                        // codepoint) — keep decoding the next token.
                        if piece.isEmpty { continue }

                        // Stop sequence detection
                        if !stopSequences.isEmpty {
                            stopBuffer += piece
                            for seq in stopSequences {
                                if stopBuffer.contains(seq) {
                                    if let range = stopBuffer.range(of: seq) {
                                        let before = String(stopBuffer[stopBuffer.startIndex..<range.lowerBound])
                                        if !before.isEmpty { continuation.yield(before) }
                                    }
                                    cacheBox?.finalPromptTokens = promptTokens
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
                            cacheBox?.finalPromptTokens = promptTokens
                            continuation.finish(throwing: RuntimeError.underlying(
                                "llama_decode failed during generation (status: \(decodeStatus))"
                            ))
                            return
                        }
                    }

                    // Max tokens reached — flush remaining buffer (and any
                    // leftover UTF-8 bytes that never completed into a valid
                    // codepoint).
                    if !pendingBytes.isEmpty {
                        stopBuffer += String(decoding: pendingBytes, as: UTF8.self)
                        pendingBytes = []
                    }
                    if !stopBuffer.isEmpty { continuation.yield(stopBuffer) }
                    cacheBox?.finalPromptTokens = promptTokens
                    continuation.finish()

                } catch {
                    cacheBox?.finalPromptTokens = []
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

    // MARK: - UTF-8 streaming helpers

    /// Splits `bytes` into the longest valid-UTF-8 prefix and the remaining
    /// (incomplete) trailing bytes. Used by the streaming hot-path so a
    /// codepoint cut between two GGUF tokens isn't substituted with U+FFFD
    /// before being yielded to the UI.
    ///
    /// Algorithm: try cuts from longest to shortest (a UTF-8 codepoint is
    /// at most 4 bytes, so we only walk back 4 positions). The first cut
    /// whose prefix validates is the answer. The empty prefix is always
    /// valid, so the loop is guaranteed to find an answer.
    static func drainValidUTF8Prefix(from bytes: [UInt8]) -> (decoded: String, leftover: [UInt8]) {
        guard !bytes.isEmpty else { return ("", []) }
        let maxLookBack = min(4, bytes.count)
        for trail in 0...maxLookBack {
            let cut = bytes.count - trail
            let prefix = Array(bytes[..<cut])
            if Self.isValidUTF8(prefix) {
                let leftover = Array(bytes[cut...])
                return (String(decoding: prefix, as: UTF8.self), leftover)
            }
        }
        // Theoretically unreachable (empty prefix always validates).
        return ("", bytes)
    }

    /// Returns `true` iff `bytes` is a complete, well-formed UTF-8 sequence.
    /// Hand-rolled to avoid `String(validating:)`, which is only available
    /// on iOS 18 / macOS 15 — HomeHub targets iOS 17.
    private static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            let need: Int
            if b < 0x80          { need = 0 }
            else if b < 0xC2     { return false }                // continuation or overlong
            else if b < 0xE0     { need = 1 }
            else if b < 0xF0     { need = 2 }
            else if b < 0xF5     { need = 3 }
            else                 { return false }
            guard i + need < bytes.count else { return false }
            if need > 0 {
                for j in 1...need {
                    let c = bytes[i + j]
                    if c < 0x80 || c > 0xBF { return false }
                }
            }
            i += need + 1
        }
        return true
    }
}
