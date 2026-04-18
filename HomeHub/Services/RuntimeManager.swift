import Foundation
import SwiftUI

/// Owns the currently active `LocalLLMRuntime` and exposes its state
/// to the UI. This is the *only* place in the app that knows about
/// model loading and unloading; everyone else talks to it.
@MainActor
final class RuntimeManager: ObservableObject {
    enum State: Equatable {
        case idle
        case loading(modelID: String)
        case ready(modelID: String)
        case failed(modelID: String?, reason: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var activeModel: LocalModel?

    let runtime: any LocalLLMRuntime

    /// Structured telemetry channel for the active runtime.
    ///
    /// Provides a live `AsyncStream<RuntimeTelemetryEvent>` covering load
    /// times, first-token latency, tokens/sec, cancellation, and memory
    /// pressure. Subscribe from any async context:
    ///
    /// ```swift
    /// let (stream, id) = await runtimeManager.telemetry.subscribe()
    /// Task { for await event in stream { handle(event) } }
    /// ```
    var telemetry: RuntimeTelemetry { runtime.telemetry }

    init(runtime: any LocalLLMRuntime) {
        self.runtime = runtime
    }

    func load(_ model: LocalModel) async {
        state = .loading(modelID: model.id)
        do {
            try await runtime.load(model: model)
            activeModel = model
            state = .ready(modelID: model.id)
        } catch {
            state = .failed(modelID: model.id, reason: error.localizedDescription)
        }
    }

    func unload() async {
        await runtime.unload()
        activeModel = nil
        state = .idle
    }

    /// Syncs `activeModel` and `state` to `.idle` without calling
    /// `runtime.unload()`. Use this when the runtime has already auto-unloaded
    /// (memory pressure, background) and `AppContainer` needs to reconcile the
    /// observable state without triggering a second unload call.
    func clearState() {
        activeModel = nil
        state = .idle
    }

    /// Thin passthrough. Services call this instead of holding a
    /// direct runtime reference so the manager stays the one place
    /// that tracks state transitions.
    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        runtime.generate(prompt: prompt, parameters: parameters)
    }

    // MARK: - KV-cache session management

    /// Removes the KV-cache session for `conversationID`.
    /// No-op when the runtime doesn't support session tracking (e.g. mock).
    func invalidateSession(for conversationID: UUID) async {
        await (runtime as? LlamaCppRuntime)?.invalidateSession(for: conversationID)
    }

    // MARK: - Lifecycle forwarding

    /// Forwards a memory-pressure event to the runtime.
    ///
    /// If the runtime auto-unloads the model in response, `RuntimeManager`
    /// syncs its own `activeModel` / `state` to `.idle` via `clearState()`.
    ///
    /// - Returns: The model that was unloaded, or `nil` if no model was loaded
    ///   or the runtime chose not to unload (e.g. policy is `.manual`).
    @discardableResult
    func handleMemoryPressure() async -> LocalModel? {
        let modelBeforeEvent = activeModel
        await runtime.handleMemoryPressure()
        guard modelBeforeEvent != nil, runtime.loadedModel == nil else { return nil }
        clearState()
        return modelBeforeEvent
    }

    /// Forwards a scene-background event to the runtime.
    ///
    /// If the runtime auto-unloads the model, `RuntimeManager` syncs its
    /// observable state to `.idle` via `clearState()`.
    ///
    /// - Returns: The model that was unloaded, or `nil` if no model was loaded
    ///   or the runtime chose not to unload (e.g. policy is `.manual`).
    @discardableResult
    func handleBackground() async -> LocalModel? {
        let modelBeforeEvent = activeModel
        await runtime.handleBackground()
        guard modelBeforeEvent != nil, runtime.loadedModel == nil else { return nil }
        clearState()
        return modelBeforeEvent
    }
}
