import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runtime backed by Apple's `FoundationModels` framework
/// (Apple Intelligence's on-device language model).
///
/// ## Why a separate runtime
///
/// The Apple Intelligence model is fundamentally different from MLX /
/// Core ML weights HomeHub manages elsewhere:
///   * **No download.** The weights are part of iOS itself — managed by
///     the OS, swapped in/out under memory pressure transparently, and
///     gated behind a system-level user opt-in (Settings → Apple
///     Intelligence). The catalog entry has no `downloadURL` and the
///     install state is synthetic `.installed`.
///   * **No model picker.** Apple ships exactly one Foundation Models
///     SystemLanguageModel — we don't get to pick parameters,
///     quantisation, or compute units. Every UI surface that lists
///     "models" treats this as a single entry.
///   * **Instant cold start.** First-token latency is typically
///     sub-second versus MLX's multi-second prefill. The
///     `loadWithProgress` path returns immediately with `.complete` —
///     there's nothing to load.
///   * **Built-in safety.** Apple's `LanguageModelSession` enforces
///     its own content filters; we don't need to layer guardrails.
///
/// ## Availability matrix
///
/// | Build SDK | Runtime iOS | Apple Intelligence | Behaviour |
/// |---|---|---|---|
/// | < 26 | n/a | n/a | File compiles to a `notAvailable` stub via `#if canImport` |
/// | ≥ 26 | < 26 | n/a | Class loads but `load(model:)` throws — gated by `if #available` |
/// | ≥ 26 | ≥ 26 | disabled / unsupported | `load(model:)` throws `notAvailable` with Czech actionable message |
/// | ≥ 26 | ≥ 26 | enabled | Works |
///
/// The chain `RoutingRuntime → AppleFoundationModelsRuntime →
/// LanguageModelSession` is deliberately thin: we don't try to
/// emulate features Apple doesn't expose (top-K sampling, repeat
/// penalty), and we don't try to hide errors Apple raises — the
/// user gets the framework's error verbatim where it's already
/// localised and actionable.
final class AppleFoundationModelsRuntime: LocalLLMRuntime, @unchecked Sendable {

    // MARK: - LocalLLMRuntime — identity

    var identifier: String { "apple-foundation-models" }

    private let logger = Logger(subsystem: "com.keksiczek.HomeHub", category: "AppleFoundationModelsRuntime")

    // MARK: - Mutable state (single-thread access enforced by RuntimeManager)

    /// Snapshot of every mutable runtime field, held under a single
    /// `OSAllocatedUnfairLock` so reads from arbitrary actors
    /// (typically `@MainActor` observers of `lastGenerationError`,
    /// `isCurrentlyGenerating`, etc.) never race writes from the
    /// cooperative-pool `Task` inside `generate(...)`.
    ///
    /// **Why a lock, not an actor.** The protocol surface declares
    /// `loadedModel`, `isCurrentlyGenerating`, `lastGenerationError`
    /// as synchronous nonisolated getters. Migrating to an actor
    /// would force `async` on every call site — a much wider
    /// surgery than the value of the change. `OSAllocatedUnfairLock`
    /// gives us O(ns) reads from any isolation context with the
    /// same nonisolated-getter ergonomics.
    ///
    /// **Why all 5 fields share one lock.** They're rarely written
    /// together but `unload()` does mutate every one of them in a
    /// burst — putting them under one lock keeps that transition
    /// atomic from any concurrent observer's perspective. Fine-
    /// grained locks would let an observer see a half-unloaded
    /// runtime (model gone but `isGenerating == true`).
    ///
    /// **Why `sessionsAny: Any?`.** Swift's stored-property
    /// availability is limited — we can't declare
    /// `sessions: [UUID: LanguageModelSession]` directly because
    /// the value type isn't available on iOS < 26. The `Any`
    /// erasure pushes the type cast to the access site (gated by
    /// `if #available`).
    fileprivate struct MutableState: @unchecked Sendable {
        var loadedModel: LocalModel? = nil
        /// Type-erased `[UUID: LanguageModelSession]` (iOS 26+).
        /// Mutated only via the `withSessions(_:)` helper below
        /// so reads and writes go through one path.
        var sessionsAny: Any? = nil
        var isGenerating: Bool = false
        var lastError: GenerationFailure? = nil
        var activeSessionID: UUID? = nil
    }

    private let lockedState = OSAllocatedUnfairLock<MutableState>(initialState: MutableState())

    // MARK: - LocalLLMRuntime — reads

    var loadedModel: LocalModel? { lockedState.withLock { $0.loadedModel } }
    var isCurrentlyGenerating: Bool { lockedState.withLock { $0.isGenerating } }
    var lastGenerationError: GenerationFailure? { lockedState.withLock { $0.lastError } }
    var activeSessionConversationID: UUID? { lockedState.withLock { $0.activeSessionID } }

    // MARK: - Session cache helpers
    //
    // Every read AND mutation of the typed `[UUID: LanguageModelSession]`
    // dictionary goes through these helpers, eliminating the
    // previous dual-write path (raw `_sessionsAny = nil` direct
    // assignment vs computed `sessions.removeAll()` setter). The
    // helpers also bury the `Any?` cast in one place so future
    // edits can't accidentally bypass it.

    #if canImport(FoundationModels)
    /// `@unchecked Sendable` box around `LanguageModelSession` so the
    /// session cache (held under `OSAllocatedUnfairLock` whose
    /// closures are `@Sendable`) can store sessions without Apple's
    /// non-Sendable type tripping strict-concurrency checks. Safe by
    /// construction: a session is mutated only by its owner runtime
    /// via `respond(to:)` / `streamResponse(to:)`, never observed
    /// concurrently across the box's reference.
    @available(iOS 26.0, *)
    private final class SessionBox: @unchecked Sendable {
        let session: LanguageModelSession
        init(_ session: LanguageModelSession) { self.session = session }
    }

    /// Look up a cached session for `conversationID`. Returns nil when
    /// nothing is cached or the cast fails (iOS < 26 path).
    @available(iOS 26.0, *)
    private func session(for conversationID: UUID) -> LanguageModelSession? {
        lockedState.withLock { state in
            (state.sessionsAny as? [UUID: SessionBox])?[conversationID]?.session
        }
    }

    /// Store `session` under `conversationID` atomically.
    @available(iOS 26.0, *)
    private func setSession(_ session: LanguageModelSession, for conversationID: UUID) {
        let box = SessionBox(session)
        lockedState.withLock { state in
            var dict = state.sessionsAny as? [UUID: SessionBox] ?? [:]
            dict[conversationID] = box
            state.sessionsAny = dict
        }
    }

    /// Remove the cached session for `conversationID` atomically.
    @available(iOS 26.0, *)
    private func removeSession(for conversationID: UUID) {
        lockedState.withLock { state in
            guard var dict = state.sessionsAny as? [UUID: SessionBox] else { return }
            dict.removeValue(forKey: conversationID)
            state.sessionsAny = dict
        }
    }
    #endif

    /// Drop the entire session cache. Called from `unload()`,
    /// `handleBackground()`, `trimMemoryCaches()` — paths where we
    /// want everything gone without re-typing. iOS < 26 is a no-op
    /// because `sessionsAny` was never populated there.
    private func clearSessionCache() {
        lockedState.withLock { state in
            state.sessionsAny = nil
        }
    }

    // MARK: - LocalLLMRuntime — load / unload

    func load(model: LocalModel) async throws {
        guard model.backend == .appleFoundationModels else {
            // Defensive: a routing bug shouldn't crash us, but the
            // user-facing error has to be specific enough that the
            // bug reporter knows where to look.
            throw RuntimeError.incompatibleModel( "Tento runtime obsluhuje pouze modely typu Apple Intelligence, dostal jsem '\(model.id)'.")
        }

        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            // Build SDK supports the framework but the runtime device
            // is on an older iOS. Surface as not-available rather than
            // a generic load failure so users on iOS 17/18 see why
            // the model shows up greyed out.
            throw RuntimeError.incompatibleModel( "Apple Intelligence vyžaduje iOS 26 nebo novější.")
        }

        // `SystemLanguageModel.default.availability` enumerates the
        // exact reason the model is or isn't usable on this device
        // (hardware ineligible, user disabled, model still
        // downloading). We translate the cases into Czech rather
        // than relying on the framework's String descriptions —
        // they're English-only and switch wording across iOS
        // releases.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw Self.translatedAvailabilityError(reason)
        @unknown default:
            throw RuntimeError.incompatibleModel( "Apple Intelligence vrátilo neznámý stav dostupnosti.")
        }

        lockedState.withLock { $0.loadedModel = model }
        logger.info("Loaded Apple Foundation Models runtime for '\(model.id, privacy: .public)'")
        #else
        throw RuntimeError.incompatibleModel( "Build aplikace neobsahuje framework FoundationModels — Apple Intelligence není v tomto buildu k dispozici.")
        #endif
    }

    func unload() async {
        // Atomic burst: clear loaded model, session cache, and
        // active session ID together so any concurrent observer
        // never sees a half-unloaded runtime (e.g. model nil but
        // session still cached). The fields share one lock for
        // exactly this transition.
        lockedState.withLock { state in
            state.sessionsAny = nil
            state.loadedModel = nil
            state.activeSessionID = nil
        }
        logger.info("Unloaded Apple Foundation Models runtime")
    }

    func invalidateSession(for conversationID: UUID) async {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            removeSession(for: conversationID)
        }
        #endif
        lockedState.withLock { state in
            if state.activeSessionID == conversationID {
                state.activeSessionID = nil
            }
        }
    }

    func handleBackground() async {
        // Apple's framework already releases compute backends under
        // OS pressure — no equivalent to MLX's eager unload needed.
        // We do flush any per-conversation transcript caches because
        // they're cheap to rebuild on the next turn and grow with
        // chat length.
        clearSessionCache()
    }

    func handleMemoryPressure() async {
        await unload()
    }

    func trimMemoryCaches() async {
        // Drop the session cache only; keep loadedModel so the
        // next turn doesn't have to round-trip through the catalog.
        // Sessions are cheap to recreate — they're handles to an
        // OS-managed model, not weights.
        clearSessionCache()
    }

    // MARK: - LocalLLMRuntime — generate

    func generate(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runGeneration(prompt: prompt, parameters: parameters, continuation: continuation)
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    private func runGeneration(
        prompt: RuntimePrompt,
        parameters: RuntimeParameters,
        continuation: AsyncThrowingStream<RuntimeEvent, Error>.Continuation
    ) async {
        #if canImport(FoundationModels)
        let currentModelID = loadedModel?.id
        guard #available(iOS 26.0, *) else {
            let err = RuntimeError.incompatibleModel("Apple Intelligence vyžaduje iOS 26 nebo novější.")
            lockedState.withLock { state in
                state.lastError = Self.failure(modelID: currentModelID ?? identifier, message: err.localizedDescription ?? "Apple Intelligence není dostupné.", kind: .backendError)
            }
            continuation.finish(throwing: err)
            return
        }

        guard currentModelID != nil else {
            let err = RuntimeError.noModelLoaded
            lockedState.withLock { state in
                state.lastError = Self.failure(modelID: identifier, message: err.localizedDescription ?? "Žádný model není načtený.", kind: .other)
            }
            continuation.finish(throwing: err)
            return
        }

        let start = Date()
        // Atomic burst on entry: set the active conversation ID,
        // mark generating, clear any prior error. One lock pass for
        // three writes so any observer reading
        // `isCurrentlyGenerating` + `lastGenerationError` together
        // sees a consistent snapshot rather than the half-state
        // between flipping the bool and clearing the error.
        let conversationID = parameters.conversationID ?? UUID()
        lockedState.withLock { state in
            state.activeSessionID = conversationID
            state.isGenerating = true
            state.lastError = nil
        }
        defer { lockedState.withLock { $0.isGenerating = false } }

        // Resolve or build a session for this conversation. Reusing
        // the session across turns is what gives us prompt-prefill
        // amortisation — without it every turn would re-tokenise the
        // full transcript. The session's instructions are pinned at
        // creation, so a system-prompt change between turns forces
        // a session rebuild (we detect it via the `instructionsKey`).

        let instructions = prompt.systemPrompt
        let existingSession = session(for: conversationID)
        let needsRebuild = parameters.forceStateless || existingSession == nil

        let session: LanguageModelSession
        if !needsRebuild, let existing = existingSession {
            session = existing
        } else {
            // **Why no transcript replay here.** Apple's
            // `LanguageModelSession.respond(to:)` is the only
            // public API for adding turns, and it always treats
            // its argument as a USER prompt — there is no
            // "preload an assistant turn" hook. An earlier draft
            // looped `respond(to:)` over every prior message which
            // accidentally fed past assistant outputs back into
            // the session as new user prompts, corrupting role
            // alternation. The cleanest correct behaviour is to
            // start the session FRESH and rely on three other
            // mechanisms for cross-turn continuity:
            //   1. The `instructions` block contains the system
            //      prompt + memory facts + skill instructions
            //      assembled by `PromptAssemblyService`, which
            //      already embeds the conversation summary +
            //      recall snippets that `ConversationService`
            //      builds for older turns.
            //   2. The session is CACHED for the lifetime of the
            //      conversation, so a second turn in the same
            //      session reuses Apple's prompt-prefill cache
            //      (the win we'd hoped to get from replay).
            //   3. The current user message goes through
            //      `respond(to:)` below as the actual user turn.
            // The trade-off: the first turn after a cold launch
            // (or after `forceStateless`) does NOT see prior
            // assistant text directly — only the recap embedded
            // in the system prompt. That's an acceptable loss
            // because the recap path is shared with MLX where
            // session state is also non-portable.
            session = LanguageModelSession(instructions: instructions)
            setSession(session, for: conversationID)
        }

        // Find the actual user input. It's the last entry in
        // `messages`; everything before is history we just replayed.
        guard let userTurn = prompt.messages.last(where: { $0.role == .user }) else {
            let err = RuntimeError.underlying("Apple Intelligence runtime nedostalo user message.")
            lockedState.withLock { state in
                state.lastError = Self.failure(modelID: currentModelID ?? identifier, message: err.localizedDescription ?? "Chybí vstup uživatele.", kind: .other)
            }
            continuation.finish(throwing: err)
            return
        }

        do {
            // `streamResponse(to:)` yields accumulated strings —
            // every emission contains the full text so far, NOT a
            // delta. We compute deltas locally so `RuntimeEvent.token`
            // matches the contract MLX uses (one event per token).
            let stream = session.streamResponse(to: userTurn.content)
            var emitted = ""
            var tokenCount = 0

            for try await snapshot in stream {
                if Task.isCancelled {
                    continuation.yield(.finished(
                        reason: .cancelled,
                        stats: Self.stats(start: start, tokens: tokenCount)
                    ))
                    continuation.finish()
                    return
                }
                let snapshotText = Self.string(from: snapshot)
                let delta = Self.deltaFromAccumulated(previous: emitted, current: snapshotText)
                guard !delta.isEmpty else { continue }
                emitted = snapshotText
                // Rough token count — Foundation Models doesn't expose
                // a public tokeniser, so we approximate one token per
                // 4 chars of UTF-8 (CLIP/BPE rule-of-thumb) for
                // throughput reporting. Diagnostics will show this
                // is approximate.
                tokenCount += max(1, delta.utf8.count / 4)
                continuation.yield(.token(delta))
            }

            continuation.yield(.finished(
                reason: .stop,
                stats: Self.stats(start: start, tokens: tokenCount)
            ))
            continuation.finish()
        } catch {
            lockedState.withLock { state in
                state.lastError = Self.failure(
                    modelID: currentModelID ?? identifier,
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    kind: .backendError
                )
            }
            // Drop the session for this conversation — Apple's
            // documentation says errored sessions can leave the
            // model in an inconsistent state. Fresh session on
            // next turn.
            removeSession(for: conversationID)
            continuation.yield(.finished(
                reason: .error,
                stats: Self.stats(start: start, tokens: 0)
            ))
            continuation.finish(throwing: error)
        }
        #else
        let err = RuntimeError.incompatibleModel( "Build aplikace neobsahuje framework FoundationModels — Apple Intelligence není k dispozici.")
        continuation.finish(throwing: err)
        #endif
    }

    // MARK: - Helpers

    /// `LanguageModelSession.streamResponse(to:)` evolved between iOS
    /// betas — older builds yielded `String`, newer ones yield a
    /// snapshot type with a `.content` property. We normalise both
    /// shapes into a plain String so the delta calculation has a
    /// single code path. If the snapshot shape changes again, this
    /// is the single point of update.
    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    // Generic over the snapshot type — `ResponseStream<String>.Snapshot`
    // is intentionally NOT Sendable (it holds non-Sendable internals
    // for Apple's incremental decoder). The helper runs synchronously
    // on the same actor that iterated the stream, so we don't need
    // Sendable here; the `any Sendable` formulation would over-
    // constrain and break compilation under Swift 6 strict concurrency.
    //
    // TODO(iOS 26.x stability): The `Mirror`-based fallback below
    // depends on Apple's snapshot type having a property literally
    // named `content`. That's true on the iOS 26.0–26.2 SDKs we've
    // built against, but it's a private detail Apple may rename
    // between betas. If a future SDK drops or renames this property
    // the fallback returns `"\(snapshot)"` (the Swift debug
    // description) which would silently corrupt every response.
    // Re-verify when bumping the build SDK; consider switching to
    // a stable `ResponseStream<String>.Output` (if Apple exposes
    // one) once GA lands.
    private static func string<S>(from snapshot: S) -> String {
        // Try direct String first (the simplest shape).
        if let s = snapshot as? String { return s }
        // Fall back to reflection: look for a `content`-shaped
        // property. The Foundation Models snapshot type isn't
        // generic in this regard — it has a single `content`
        // String. This is intentionally defensive.
        let mirror = Mirror(reflecting: snapshot)
        for child in mirror.children {
            if child.label == "content", let s = child.value as? String { return s }
        }
        return "\(snapshot)"
    }
    #endif

    /// Compute the new-tokens delta from two accumulated snapshots.
    /// Returns whatever's appended to `previous` in `current`.
    /// If `current` doesn't share `previous` as a prefix (rare —
    /// happens when the model issues a token-level correction), we
    /// fall back to yielding the whole `current` as the delta;
    /// duplicating a few tokens is better than dropping a correction.
    private static func deltaFromAccumulated(previous: String, current: String) -> String {
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        return current
    }

    private static func stats(start: Date, tokens: Int) -> RuntimeStats {
        let elapsed = Date().timeIntervalSince(start)
        let tps = elapsed > 0 ? Double(tokens) / elapsed : 0
        return RuntimeStats(
            tokensGenerated: tokens,
            tokensPerSecond: tps,
            totalDurationMs: Int(elapsed * 1000)
        )
    }

    /// Shorthand for the GenerationFailure constructor — Apple
    /// Intelligence runtime always reports `backend: "apple"` and
    /// stamps `occurredAt` to `now`.
    private static func failure(modelID: String, message: String, kind: GenerationFailure.Kind) -> GenerationFailure {
        GenerationFailure(modelID: modelID, backend: "apple", kind: kind, message: message, occurredAt: Date())
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func translatedAvailabilityError(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> RuntimeError {
        switch reason {
        case .deviceNotEligible:
            return .incompatibleModel( "Toto zařízení Apple Intelligence nepodporuje. Vyžaduje se iPhone 15 Pro / 16 / 16 Pro nebo iPad / Mac s M-series čipem.")
        case .appleIntelligenceNotEnabled:
            return .incompatibleModel( "Apple Intelligence není zapnuté. Otevři Nastavení → Apple Intelligence & Siri a aktivuj jej.")
        case .modelNotReady:
            return .incompatibleModel( "Apple Intelligence se stále stahuje. Zkus to za pár minut.")
        @unknown default:
            return .incompatibleModel( "Apple Intelligence není dostupné na tomto zařízení.")
        }
    }
    #endif
}
