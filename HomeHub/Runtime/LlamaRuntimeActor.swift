import Foundation

// MARK: - GenerationCancellationToken

/// Shared cancellation signal between `LlamaRuntimeActor` (writer) and a
/// generation `Task` (reader).
///
/// ## Why not store `Task` references in the actor?
/// Storing `Task` references and calling `.cancel()` directly works, but
/// requires complex bookkeeping to register/deregister tasks atomically.
/// A shared token is simpler: the actor writes `isCancelled = true` once,
/// and all generation tasks that hold a reference to the same token observe
/// the change on their next iteration.
///
/// ## Thread safety
/// `isCancelled` is written exactly once — by `LlamaRuntimeActor` — under
/// actor isolation, then read many times (lock-free). `NSLock` guards the
/// write so the read side on non-actor threads sees the update promptly
/// without relying on memory-ordering assumptions.
final class GenerationCancellationToken: @unchecked Sendable {

    private let lock = NSLock()
    private var _isCancelled = false

    /// True after `cancel()` has been called. Generation tasks poll this
    /// before each token: when true they yield `.finished(.cancelled)` and
    /// stop decoding.
    var isCancelled: Bool {
        lock.withLock { _isCancelled }
    }

    /// Marks the token as cancelled. Idempotent.
    func cancel() {
        lock.withLock { _isCancelled = true }
    }
}

// MARK: - LlamaRuntimeActor

/// Actor that owns and serialises access to the llama.cpp engine state.
///
/// `LlamaCppRuntime` is the public `LocalLLMRuntime` conformance; this
/// actor owns the mutable internals: the loaded-model metadata, the C++
/// context handle, and the per-generation cancellation token.
///
/// ## Why an actor?
/// - **Compiler-checked exclusivity** — stored properties are protected by
///   the actor's executor; no `NSLock` needed on the state itself.
/// - **Sequential lifecycle** — `load` and `unload` are queued if called
///   concurrently; one always completes before the next starts.
///
/// ## Reentrancy contract: load / unload / generate
///
/// **`load` vs `unload`**: serialised by the actor. Each call runs to
/// completion before the next is serviced. Safe.
///
/// **`unload` vs `generate`** (the interesting case):
/// 1. `unload()` calls `currentCancellationToken.cancel()` — sets the
///    shared flag that all active generation tasks poll.
/// 2. A fresh token is installed for the next generation.
/// 3. `context?.close()` frees the C++ context.
/// 4. Any in-flight generation Task checks `cancellationToken.isCancelled`
///    before each token decode. It yields `.finished(.cancelled, stats)`
///    and returns without calling back into the (now-freed) C++ context.
///
/// **Guarantee**: at most one extra token may be decoded after `unload()`
/// is called — the one already in flight when the cancel flag is set. That
/// token is discarded (not yielded to the caller). The caller always
/// receives a clean `.finished(.cancelled, ...)` stream termination.
///
/// **C++ close() thread safety**: when `close()` is called while an
/// in-progress `llama_decode` is running on the actor thread, the real
/// bridge must either (a) use an internal mutex so `close()` waits for
/// the decode to finish, or (b) return an error from decode when the
/// context is in a closing state — not undefined behaviour.
/// TODO: Add a generation ref-count or mutex to the C++ bridge layer.
///
/// **`load` vs `generate`**: if `load()` is called while generation is
/// running, the actor queues `load()` behind the current `contextSnapshot`
/// hop. `unload()` is called as part of `load()`, which cancels the running
/// generation via the token before the new context is created. Safe.
actor LlamaRuntimeActor {

    // MARK: - State

    private(set) var loadedModel: LocalModel?
    private var context: LlamaContextHandle?

    /// Shared cancellation token for the currently-active generation.
    /// Replaced on every `load()` or `unload()` call.
    private(set) var currentCancellationToken = GenerationCancellationToken()

    /// Per-conversation KV-cache session records.
    /// Keyed by `conversationID`; cleared when the model is unloaded because
    /// a freshly-loaded model always starts with an empty KV cache.
    private var sessions: [UUID: ConversationRuntimeSession] = [:]

    /// Prevents concurrent access to the C++ llama_context*.
    /// llama.cpp is single-threaded — only one generate() may run at a time.
    private var isGenerating = false

    /// `pendingClose` is true when unload()/load() was called while a generation
    /// was active. The actual close() is deferred to returnFromGeneration() so
    /// llama_decode never races with llama_free (SIGBUS).
    private var pendingClose = false

    /// Contexts that must be closed once the active generation finishes.
    /// A list (not a single slot) so rapid unload→load sequences don't lose
    /// a context reference if both arrive before returnFromGeneration() fires.
    private var contextsToClose: [LlamaContextHandle] = []

    // MARK: - Load

    /// Closes any existing context and loads `model` from `path`.
    ///
    /// Before attempting the new load, the current cancellation token is
    /// cancelled so any in-flight generation tasks stop cleanly. A fresh
    /// token is always installed, even on load failure — so a retry always
    /// gets a non-cancelled token.
    ///
    /// - Throws: `RuntimeError.incompatibleModel`, `.outOfMemory`, or
    ///   `.underlying` as forwarded from `LlamaContextHandle.load`.
    ///
    /// Safe: actor ensures no concurrent mutation of state.
    func load(model: LocalModel, path: String) throws {
        // Signal any active generation Tasks to stop.
        // They hold a reference to the old token and will see isCancelled = true
        // on their next iteration, before decoding another token from the old context.
        currentCancellationToken.cancel()
        currentCancellationToken = GenerationCancellationToken()

        if isGenerating, let old = context {
            // A generation task is still running — it holds a copy of `old`
            // and may be inside llama_decode right now. Calling old.close()
            // here would race with that decode and cause a SIGBUS / use-after-free.
            // Defer close() to returnFromGeneration(), which is called from the
            // generation task's defer block — i.e., after the task exits C++.
            contextsToClose.append(old)
            pendingClose = true
        } else {
            context?.close()
        }
        context = nil
        loadedModel = nil

        // If this throws, all state stays nil and the fresh token is non-cancelled —
        // correct for a subsequent retry.
        let capabilities = ModelCapabilityProfile.resolve(family: model.family)
        let ctx = try LlamaContextHandle.load(
            modelPath: path,
            contextLength: model.contextLength,
            gpuLayers: .maximum,
            capabilities: capabilities
        )
        context = ctx
        loadedModel = model
    }

    // MARK: - Unload

    /// Frees the C++ context and clears all state.
    ///
    /// Idempotent: safe to call when nothing is loaded. Cancels the current
    /// generation token so in-flight generation tasks terminate cleanly.
    ///
    /// When a generation is active, `close()` is deferred to
    /// `returnFromGeneration()` to prevent a SIGBUS race with `llama_decode`.
    func unload() {
        currentCancellationToken.cancel()
        currentCancellationToken = GenerationCancellationToken()

        if isGenerating, let old = context {
            // Same deferred-close pattern as load(): don't touch the C++ pointer
            // while the generation task may be inside llama_decode.
            contextsToClose.append(old)
            pendingClose = true
            // isGenerating stays true — returnFromGeneration() will clear it.
        } else {
            context?.close()
        }
        context = nil
        loadedModel = nil
        sessions.removeAll()
    }

    // MARK: - Session management

    /// Returns the KV-cache session for `id`, or `nil` if none exists.
    func session(for id: UUID) -> ConversationRuntimeSession? {
        sessions[id]
    }

    /// Stores or replaces the session record for `session.conversationID`.
    func updateSession(_ session: ConversationRuntimeSession) {
        sessions[session.conversationID] = session
    }

    /// Removes the session record for `id`. Call from `deleteConversation`.
    func removeSession(for id: UUID) {
        sessions[id] = nil
    }

    // MARK: - Borrow for generation

    /// Returns the active context and the current cancellation token in a
    /// single actor hop — atomically from the generation Task's perspective.
    ///
    /// The generation Task holds the token for the duration of its loop.
    /// If `unload()` races after this call:
    /// - The token is cancelled → the Task sees `isCancelled = true` before
    ///   its next decode call and yields `.finished(.cancelled)`.
    /// - `close()` frees the C++ context. At most one token may still be
    ///   in-flight inside C++ (the one decode that started before `close()`).
    ///   See class-level doc for the C++ thread-safety TODO.
    ///
    /// **Do not store the returned `LlamaContextHandle` beyond one generation
    /// Task's lifetime.**
    ///
    /// - Throws: `RuntimeError.noModelLoaded` if no model is loaded.
    func borrowForGeneration() throws -> (context: LlamaContextHandle, token: GenerationCancellationToken) {
        guard let ctx = context else { throw RuntimeError.noModelLoaded }
        guard !isGenerating else { throw RuntimeError.noModelLoaded }
        isGenerating = true
        return (ctx, currentCancellationToken)
    }

    func returnFromGeneration() {
        isGenerating = false
        if pendingClose {
            // The generation task has exited — it is safe to free the C++ contexts
            // that were queued while the task was alive.
            contextsToClose.forEach { $0.close() }
            contextsToClose.removeAll()
            pendingClose = false
        }
    }
}
