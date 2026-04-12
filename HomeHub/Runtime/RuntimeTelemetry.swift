import Foundation

// MARK: - ModelHandle

/// Lightweight, Sendable identity token for a loaded model.
///
/// A future model orchestrator uses `ModelHandle` to answer
/// "is the same model still loaded?" without carrying the full
/// `LocalModel` metadata across concurrency boundaries.
///
/// Included in every telemetry event so subscribers always know
/// which model the event refers to, even after a swap.
struct ModelHandle: Sendable, Equatable, Hashable {
    let modelID: String
    let displayName: String
    let loadedAt: Date

    init(from model: LocalModel) {
        modelID    = model.id
        displayName = model.displayName
        loadedAt   = .now
    }
}

// MARK: - UnloadReason

/// Records why the runtime released a loaded model.
///
/// Used in telemetry events and in the `UnloadPolicy` evaluation.
/// Helps correlate memory-reclaim events with device conditions for
/// future product analysis.
enum UnloadReason: String, Sendable, CustomStringConvertible {
    /// Caller explicitly called `unload()` or `RuntimeManager.unload()`.
    case manual
    /// System delivered a memory-pressure notification.
    case memoryPressure
    /// App moved to the background (scene-phase `.background`).
    case appBackground
    /// A new model load was requested; the old context was torn down first.
    case newModelLoading

    var description: String { rawValue }
}

// MARK: - RuntimeTelemetryEvent

/// All observable events produced by the local LLM runtime.
///
/// Subscribers receive these over an `AsyncStream` from `RuntimeTelemetry`.
/// Together they provide end-to-end visibility into:
///
/// - **Model lifecycle** — load / unload times and reasons.
/// - **Generation latency** — TTFT, tokens per second, total duration.
/// - **Cancellation** — distinguishes user cancellation from unload-driven
///   cancellation for future analytics.
/// - **Memory pressure** — tracks frequency relative to generation events.
///
/// ## Usage
/// ```swift
/// let (stream, id) = await container.runtimeManager.telemetry.subscribe()
/// Task {
///     for await event in stream {
///         switch event {
///         case .modelLoaded(let h, let ms):
///             print("'\(h.displayName)' ready in \(ms)ms")
///         case .firstToken(_, let ms):
///             updateLatencyLabel("\(ms)ms")
///         case .generationFinished(_, let stats, _):
///             print("\(stats.tokensPerSecond, format: .number) t/s")
///         default: break
///         }
///     }
/// }
/// // Cleanup:
/// await container.runtimeManager.telemetry.unsubscribe(id: id)
/// ```
enum RuntimeTelemetryEvent: Sendable {
    /// Model weights were loaded successfully into memory.
    case modelLoaded(handle: ModelHandle, durationMs: Int)

    /// The model was unloaded and memory reclaimed.
    case modelUnloaded(handle: ModelHandle, reason: UnloadReason)

    /// A generation stream was opened. Use `requestID` to correlate with
    /// subsequent `firstToken` / `generationFinished` / `generationCancelled`.
    case generationStarted(requestID: UUID, handle: ModelHandle)

    /// First decoded token was emitted. `latencyMs` is measured from
    /// `generationStarted` — the canonical TTFT metric.
    case firstToken(requestID: UUID, latencyMs: Int)

    /// Generation ran to natural completion (EOS or token budget).
    case generationFinished(
        requestID: UUID,
        stats: RuntimeStats,
        reason: RuntimeEvent.FinishReason
    )

    /// Generation was stopped early — either by `Task` cancellation or
    /// because `unload()` cancelled the generation token. Check whether
    /// the caller's `Task` was cancelled to distinguish the two.
    case generationCancelled(requestID: UUID, partialStats: RuntimeStats)

    /// The OS delivered a memory-pressure warning.
    case memoryPressureReceived
}

// MARK: - RuntimeTelemetry

/// Lightweight pub-sub channel for `RuntimeTelemetryEvent`s.
///
/// ## Design
/// - Actor-isolated: emit / subscribe / unsubscribe are all async and
///   never block the calling thread.
/// - Per-subscriber buffer (default 64 events). When a subscriber falls
///   behind, older events are dropped — the emitter is never blocked.
/// - `RuntimeTelemetry.noOp` is a shared instance with no subscribers;
///   use it as the default for test stubs and `MockLocalRuntime`.
///
/// ## Thread safety
/// `subscribe()` returns a plain `AsyncStream` value; the stream itself
/// is `Sendable` and can be consumed from any concurrency context.
actor RuntimeTelemetry {

    // MARK: - Shared no-op instance

    /// A shared instance that accepts events and immediately discards them.
    /// Used as the default `telemetry` for `MockLocalRuntime` and test stubs,
    /// keeping the protocol requirement zero-cost in non-production contexts.
    static let noOp = RuntimeTelemetry()

    // MARK: - Internal state

    private struct Subscription {
        let continuation: AsyncStream<RuntimeTelemetryEvent>.Continuation
    }

    private var subscriptions: [UUID: Subscription] = [:]
    private let bufferSize: Int

    // MARK: - Init

    init(bufferSize: Int = 64) {
        self.bufferSize = bufferSize
    }

    // MARK: - Subscribe / Unsubscribe

    /// Opens a new subscription and returns the live event stream.
    ///
    /// - Returns: `(stream, id)` where `id` is the opaque token to pass
    ///   to `unsubscribe(id:)` when the subscriber no longer needs events.
    ///   Forgetting to unsubscribe is safe but leaks the buffer until the
    ///   `RuntimeTelemetry` actor is deallocated.
    func subscribe() -> (stream: AsyncStream<RuntimeTelemetryEvent>, id: UUID) {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: RuntimeTelemetryEvent.self,
            bufferingPolicy: .bufferingNewest(bufferSize)
        )
        let subscriptionID = id
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.unsubscribe(id: subscriptionID) }
        }
        subscriptions[id] = Subscription(continuation: continuation)
        return (stream, id)
    }

    /// Closes a subscription and finishes its stream.
    func unsubscribe(id: UUID) {
        subscriptions.removeValue(forKey: id)?.continuation.finish()
    }

    // MARK: - Emit

    /// Broadcasts `event` to all current subscribers.
    ///
    /// Non-blocking from the caller's perspective: the actor serialises
    /// the yield to each subscriber's buffer asynchronously. Subscribers
    /// that have filled their buffer silently drop the oldest event.
    func emit(_ event: RuntimeTelemetryEvent) {
        for sub in subscriptions.values {
            sub.continuation.yield(event)
        }
    }
}
