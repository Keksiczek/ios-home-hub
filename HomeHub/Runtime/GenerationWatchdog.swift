import Foundation
import os

/// Non-fatal stall detector for token streaming.
///
/// Spins up a sibling Task that polls a shared "last token at"
/// timestamp every 5 s. When the silence window crosses 30 s / 60 s /
/// 120 s it emits a single `RuntimeEvent.warning(.generationStall)`
/// for that threshold so the UI can surface a banner without
/// disturbing the actual decode.
///
/// ## Why a class rather than an actor
///
/// The stream consumer (`for try await piece in responseStream`) is
/// on the generation Task and must hit `recordToken()` synchronously
/// — an `await` per token would meaningfully slow generation on
/// devices that already manage 60+ tokens/s. An `NSLock`-wrapped
/// `Date` is contention-cheap (uncontested locks on Apple Silicon
/// are well under 100 ns) and keeps the type `Sendable`-safe via
/// final class + locked mutable state.
///
/// ## Lifecycle
///
/// - `start()` records the start time and launches the polling task.
/// - `recordToken()` is called every token; resets the silence window.
/// - `stop()` cancels the polling task and is idempotent. Always
///   `defer`-pair it with `start()` to guarantee the polling task
///   doesn't outlive the generation on error/cancel paths.
final class GenerationWatchdog: @unchecked Sendable {

    private let log: Logger
    private let conversationID: UUID
    private let continuation: AsyncThrowingStream<RuntimeEvent, Error>.Continuation
    private let lock = NSLock()
    private var lastTokenAt: Date
    private var firedThresholds: Set<Int> = []
    private var pollTask: Task<Void, Never>?
    private var stopped = false

    /// Stall thresholds in seconds. One warning fires per threshold per
    /// generation; resetting the silence window (i.e. a token arrives)
    /// rearms all thresholds again so a second stall later in the same
    /// generation is also reported.
    private static let thresholds: [Int] = [30, 60, 120]

    init(
        log: Logger,
        conversationID: UUID,
        continuation: AsyncThrowingStream<RuntimeEvent, Error>.Continuation
    ) {
        self.log = log
        self.conversationID = conversationID
        self.continuation = continuation
        self.lastTokenAt = .distantPast
    }

    /// Begins watching. Safe to call once; subsequent calls are no-ops.
    func start() {
        lock.lock()
        guard pollTask == nil, !stopped else { lock.unlock(); return }
        lastTokenAt = Date()
        lock.unlock()

        pollTask = Task.detached(priority: .utility) { [weak self] in
            // 5 s poll cadence — fine-grained enough that 30 s
            // threshold fires within ~5 s of the actual stall, coarse
            // enough that the task barely costs anything.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                self?.tick()
            }
        }
    }

    /// Resets the silence window. Call from every token-arrival path.
    func recordToken() {
        lock.lock()
        lastTokenAt = Date()
        // Rearm the thresholds so a later stall in the same generation
        // is also reported. Without this, a model that stalls twice in
        // one reply would only surface the first.
        if !firedThresholds.isEmpty {
            firedThresholds.removeAll()
        }
        lock.unlock()
    }

    /// Cancels the polling task. Idempotent.
    func stop() {
        lock.lock()
        stopped = true
        let task = pollTask
        pollTask = nil
        lock.unlock()
        task?.cancel()
    }

    private func tick() {
        lock.lock()
        let silentFor = Int(Date().timeIntervalSince(lastTokenAt))
        var toFire: Int?
        for threshold in Self.thresholds where silentFor >= threshold && !firedThresholds.contains(threshold) {
            toFire = threshold
            firedThresholds.insert(threshold)
        }
        lock.unlock()

        guard let threshold = toFire else { return }
        let message = Self.stallMessage(forThreshold: threshold)
        log.warning("MLX: generation stall \(threshold)s for \(self.conversationID, privacy: .public)")
        continuation.yield(.warning(RuntimeWarning(
            kind: .generationStall,
            message: message,
            secondsSilent: silentFor
        )))
    }

    /// Locale-aware stall message. Picks Czech or English based on the
    /// current Locale's primary language so users on an English iOS
    /// don't see a Czech banner (the rest of the app routes copy via
    /// `AppLanguage` but the watchdog has no access to settings — it's
    /// constructed inside the MLX runtime which is purely async).
    ///
    /// Returns the localized free-form sentence; the threshold value
    /// is interpolated by the caller's `\(threshold)` only on the
    /// catch-all branch where the timing isn't a magic number.
    static func stallMessage(forThreshold threshold: Int) -> String {
        let isCzech = Locale.current.language.languageCode?.identifier.lowercased() == "cs"
        switch (threshold, isCzech) {
        case (30, true):  return "Model neodpovídá déle než 30 s — pravděpodobně kompiluje Metal pipeline."
        case (30, false): return "Model has been silent for more than 30 s — probably compiling the Metal pipeline."
        case (60, true):  return "Model je tichý více než 60 s — můžeš dál čekat nebo generování zrušit."
        case (60, false): return "Model has been silent for over 60 s — keep waiting or cancel the generation."
        case (_, true):   return "Model je tichý více než \(threshold) s — pokud se generování zdá zaseknuté, zkus Cancel."
        case (_, false):  return "Model has been silent for over \(threshold) s — if it seems stuck, try Cancel."
        }
    }
}
