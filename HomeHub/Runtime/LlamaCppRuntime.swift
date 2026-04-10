import Foundation
import os

/// V1 preferred local runtime, backed by `llama.cpp` compiled as an
/// xcframework with the Metal backend enabled.
///
/// ## Architecture
///
/// `LlamaCppRuntime` is a thin façade that:
/// 1. Conforms to `LocalLLMRuntime` — the only interface the rest of the
///    app ever talks to (via `RuntimeManager`).
/// 2. Delegates all mutable C++ state to `LlamaRuntimeActor`. No `NSLock`
///    needed; the actor provides compiler-checked exclusive access.
/// 3. Measures and logs load time, first-token latency, and tokens/second.
///
/// See `LlamaContextHandle.swift` for step-by-step xcframework integration.
///
/// ## loadedModel sync access
///
/// The `LocalLLMRuntime` protocol requires a *synchronous* `loadedModel`
/// property (so `MemoryExtractionService` and other actors can gate on it
/// without an extra async hop). We satisfy this with a lightweight mirror
/// `_loadedModel` that is written immediately after each actor-serialised
/// `load` / `unload` completes. Because both `RuntimeManager.load()` and
/// `RuntimeManager.unload()` are called on the `@MainActor`, the writes to
/// `_loadedModel` always happen on the main actor; the window between the
/// actor commit and the mirror update is a single suspension point that no
/// caller in the current app can observe with a visible race.
/// `@unchecked Sendable` acknowledges this accepted trade-off.
///
/// ## Why not llama.cpp + MLX?
/// V1 ships llama.cpp for broad device support (iPhone 12+ / all iPads).
/// A future `MLXRuntime` can take over on M-series iPads where MLX gives
/// better throughput, backed by the same `LocalLLMRuntime` protocol.
final class LlamaCppRuntime: LocalLLMRuntime, @unchecked Sendable {

    let identifier = "llama.cpp"

    // MARK: - State

    /// Owns the C++ context and model info; serialises all mutations.
    private let runtimeActor = LlamaRuntimeActor()

    /// Sync-accessible cache — see class-level doc for threading contract.
    private var _loadedModel: LocalModel?

    private let log = Logger(subsystem: "HomeHub", category: "LlamaCppRuntime")

    // MARK: - LocalLLMRuntime

    var loadedModel: LocalModel? { _loadedModel }

    // MARK: - Load

    func load(model: LocalModel) async throws {
        guard case .installed(let url) = model.installState else {
            throw RuntimeError.modelNotInstalled
        }

        let started = Date()

        // The actor's load() is synchronous (blocking I/O on the actor thread).
        // It may take several seconds for multi-GB models; the main actor is
        // free while we await the result.
        do {
            try await runtimeActor.load(model: model, path: url.path)
        } catch let runtimeError as RuntimeError {
            throw runtimeError
        } catch {
            throw RuntimeError.underlying(error.localizedDescription)
        }

        _loadedModel = model

        let loadMs = Int(Date().timeIntervalSince(started) * 1_000)
        log.info("Model loaded: '\(model.displayName, privacy: .public)' in \(loadMs)ms")
        #if DEBUG
        print("[LlamaCppRuntime] ✓ '\(model.displayName)' loaded in \(loadMs)ms")
        #endif
    }

    // MARK: - Unload

    func unload() async {
        await runtimeActor.unload()
        _loadedModel = nil
        log.info("Model unloaded.")
    }

    // MARK: - Generate

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        // Capture only Sendable values for the detached Task.
        let actor = runtimeActor
        let log = log

        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                // --- Context acquisition ---
                // Single actor hop: we get a value-copy of the context handle.
                // If unload() is called after this point the C++ layer will
                // error on the next decode; we surface that as a stream error.
                let ctx: LlamaContextHandle
                do {
                    ctx = try await actor.contextSnapshot()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let renderedPrompt = ChatTemplate.render(prompt)
                let started = Date()
                var tokens = 0
                var firstTokenDate: Date? = nil

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
                            let stats = Self.makeStats(tokens: tokens, started: started)
                            continuation.yield(.finished(reason: .cancelled, stats: stats))
                            continuation.finish()
                            return
                        }

                        // --- First-token latency ---
                        if firstTokenDate == nil {
                            firstTokenDate = Date()
                            let ttftMs = Int(firstTokenDate!.timeIntervalSince(started) * 1_000)
                            log.debug("First-token latency: \(ttftMs)ms")
                            #if DEBUG
                            print("[LlamaCppRuntime] TTFT: \(ttftMs)ms")
                            #endif
                        }

                        tokens += 1
                        continuation.yield(.token(piece))
                    }

                    let stats = Self.makeStats(tokens: tokens, started: started)
                    log.info(
                        "Generation done: \(stats.tokensGenerated) tokens @ " +
                        "\(String(format: "%.1f", stats.tokensPerSecond), privacy: .public) t/s"
                    )
                    #if DEBUG
                    print(
                        "[LlamaCppRuntime] \(stats.tokensGenerated) tokens " +
                        "@ \(String(format: "%.1f", stats.tokensPerSecond)) t/s " +
                        "(\(stats.totalDurationMs)ms total)"
                    )
                    #endif
                    continuation.yield(.finished(reason: .stop, stats: stats))
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

    // MARK: - Memory pressure

    /// Unloads the model to reclaim memory.
    ///
    /// Call this when the app moves to the background or receives a memory
    /// warning. Wire into the App lifecycle in `HomeHubApp.swift`:
    ///
    /// ```swift
    /// .onReceive(NotificationCenter.default.publisher(
    ///     for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
    ///     Task { await container.runtimeManager.unload() }
    /// }
    /// ```
    ///
    /// TODO: Integrate with `ScenePhase.background` via `HomeHubApp` so the
    /// model is automatically unloaded when the app is backgrounded, freeing
    /// memory for other apps on the device.
    func handleMemoryPressure() async {
        log.warning("Memory pressure received — unloading model.")
        await unload()
    }

    // MARK: - Private helpers

    private static func makeStats(tokens: Int, started: Date) -> RuntimeStats {
        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        return RuntimeStats(
            tokensGenerated: tokens,
            tokensPerSecond: Double(tokens) / elapsed,
            totalDurationMs: Int(elapsed * 1_000)
        )
    }
}
