import Foundation

/// Actor that owns and serialises access to the llama.cpp engine state.
///
/// `LlamaCppRuntime` is the public `LocalLLMRuntime` conformance; this
/// actor owns the mutable guts: the loaded-model metadata and the C++
/// context handle. Using an actor instead of `NSLock` gives us:
///
/// - **Compiler-checked exclusivity** — the stored properties are protected
///   by the actor's executor; no manual lock/unlock.
/// - **Sequential lifecycle** — `load` and `unload` are automatically
///   queued if called concurrently; one always completes before the next
///   starts.
/// - **No `@unchecked Sendable` on the state** — the actor itself is
///   `Sendable`, so its references can cross concurrency domains safely.
///
/// ## Reentrancy: load / unload / generate
///
/// `load()` and `unload()` run to completion before the next actor call
/// is serviced — Swift's actor model guarantees this.
///
/// `generate()` (in `LlamaCppRuntime`) borrows the context via
/// `contextSnapshot()`, which is a single actor hop. After that the
/// generation `Task` runs outside the actor. If `unload()` is called
/// while a generation is in progress the actor queues it; `unload` wins
/// once the actor is free again and closes the C++ context. The generation
/// Task will then see an error from the C++ layer on the next token decode
/// and surface it as a stream error — no crash.
///
/// TODO: Add a generation reference counter so `unload()` can optionally
/// await in-flight generations before freeing the C++ context. This is a
/// correctness nice-to-have once the real bridge is wired in.
actor LlamaRuntimeActor {

    // MARK: - State

    private(set) var loadedModel: LocalModel?
    private var context: LlamaContextHandle?

    // MARK: - Load

    /// Closes any existing context, then loads `model` from `path`.
    ///
    /// Called from `LlamaCppRuntime.load(model:)` which always runs on the
    /// `@MainActor` executor (via `RuntimeManager`). The actual
    /// `LlamaContextHandle.load` call is synchronous and may block the
    /// actor's thread for several seconds while the model is mapped into
    /// memory — this is intentional; the main actor remains free.
    ///
    /// - Throws: `RuntimeError.incompatibleModel`, `.outOfMemory`, or
    ///   `.underlying` as forwarded from `LlamaContextHandle.load`.
    func load(model: LocalModel, path: String) throws {
        // Close any existing context first.
        // Safe: actor ensures no concurrent mutation of `context`.
        context?.close()
        context = nil
        loadedModel = nil

        let ctx = try LlamaContextHandle.load(
            modelPath: path,
            contextLength: model.contextLength,
            gpuLayers: .maximum
        )
        context = ctx
        loadedModel = model
    }

    // MARK: - Unload

    /// Frees the C++ context and clears all model metadata.
    ///
    /// Idempotent: safe to call when no model is loaded.
    func unload() {
        context?.close()
        context = nil
        loadedModel = nil
    }

    // MARK: - Context access

    /// Returns a value-copy of the active context handle for use in one
    /// generation Task.
    ///
    /// The returned copy is valid as long as `unload()` hasn't been called.
    /// If `unload()` races after this call the C++ context will be freed;
    /// subsequent token-decode calls on the stale handle will error, which
    /// the generation Task surfaces as a stream error rather than a crash
    /// (assuming the bridge handles use-after-free gracefully).
    ///
    /// - Throws: `RuntimeError.noModelLoaded` if no model is currently loaded.
    func contextSnapshot() throws -> LlamaContextHandle {
        guard let ctx = context else {
            throw RuntimeError.noModelLoaded
        }
        return ctx
    }
}
