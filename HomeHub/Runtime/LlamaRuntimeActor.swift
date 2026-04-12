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

        context?.close()
        context = nil
        loadedModel = nil

        // If this throws, all state stays nil and the fresh token is non-cancelled —
        // correct for a subsequent retry.
        let ctx = try LlamaContextHandle.load(
            modelPath: path,
            contextLength: model.contextLength,
            gpuLayers: .maximum
        )
        context = ctx
        loadedModel = model
    }

    // MARK: - Unload

    /// Frees the C++ context and clears all state.
    ///
    /// Idempotent: safe to call when nothing is loaded. Cancels the current
    /// generation token so in-flight generation tasks terminate cleanly.
    func unload() {
        currentCancellationToken.cancel()
        currentCancellationToken = GenerationCancellationToken()
        context?.close()
        context = nil
        loadedModel = nil
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
        return (ctx, currentCancellationToken)
    }
}
