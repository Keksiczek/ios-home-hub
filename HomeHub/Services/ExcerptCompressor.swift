import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Fast helps smart" file-excerpt compressor for the
/// `RoutingPolicy.experimental` path.
///
/// ## What it does
///
/// When `ConversationService` is about to assemble a prompt for a
/// SMART-tier model and the file-excerpts payload exceeds a byte
/// threshold, this service compresses the excerpts via Apple
/// Intelligence's on-device model into a single tight paragraph.
/// The smart model then prefills a much smaller context window,
/// trading a sub-second Apple Intelligence round-trip for tens of
/// seconds of MLX prefill on long documents.
///
/// ## Why Apple Intelligence specifically
///
/// On iPhone 16 Pro (8 GB RAM), keeping two MLX models resident
/// (a fast helper + the smart workhorse) would jetsam the chat
/// surface. Apple Intelligence lives outside HomeHub's memory
/// budget — managed by iOS, instant TTFT, no load cost — making
/// it the only viable co-resident "helper" runtime on this
/// hardware. When AFM isn't available (iOS < 26, hardware
/// ineligible, user disabled), the compressor returns `nil` and
/// `ConversationService` falls back to injecting the verbatim
/// excerpts. The feature degrades to a no-op rather than
/// silently breaking the chat.
///
/// ## Threshold
///
/// `ConversationService.excerptCompressionByteThreshold` (6 KB ≈
/// 1,500 tokens) — chosen because:
///   - Below 6 KB, the AFM round-trip cost (~300-800 ms) exceeds
///     the prefill savings on the smart model.
///   - Above 6 KB, the smart model's verbatim prefill grows
///     visibly slower than AFM compression + smaller prefill.
///   - The threshold is internal — not exposed in Settings —
///     because there's no useful per-user value to tune.
///
/// ## Cancellation
///
/// AFM's `LanguageModelSession.respond(to:)` is async and
/// propagates `Task.isCancelled` natively. If the user taps Stop
/// during compression, the awaitable throws `CancellationError`,
/// `compress(...)` catches and returns `nil`, and the caller
/// injects the original excerpts. The smart model never loads.
///
/// ## Soft timeout
///
/// Compression is racing against a 4 s deadline via `TaskGroup`.
/// If AFM hangs longer than that we abandon — by that point we've
/// already lost the prefill-saving budget and might as well send
/// verbatim. Prevents a stalled helper from blocking every turn.
@MainActor
final class ExcerptCompressor {

    /// Identifier used in logs to distinguish this compressor from
    /// the main runtime — searching `os_log` for "ExcerptCompressor"
    /// surfaces only summarisation events, not main chat traffic.
    /// `nonisolated` because the TaskGroup children that read it
    /// run on the cooperative pool, not the MainActor.
    nonisolated(unsafe) private static let logger = Logger(subsystem: "com.keksiczek.HomeHub", category: "ExcerptCompressor")

    /// Soft deadline. Anything beyond this and the caller has
    /// already paid more than the smart prefill would have cost,
    /// so we bail and inject verbatim. `nonisolated` for the same
    /// reason as `logger`.
    nonisolated static let timeoutSeconds: TimeInterval = 4.0

    /// Compress `excerpts` into one paragraph via Apple
    /// Intelligence. Returns `nil` when:
    ///   - Apple Intelligence is unavailable in this build / on
    ///     this device / for this user (compressor is a no-op).
    ///   - The AFM call errored out (any throw maps to `nil`).
    ///   - The 4 s soft timeout elapsed before AFM returned.
    ///   - The task was cancelled (user tapped Stop).
    ///
    /// Returns the compressed paragraph on success — the caller
    /// substitutes it for the original `excerpts` array (as a
    /// single-element `[summary]`).
    static func compress(excerpts: [String], language: AppLanguage) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            logger.debug("Skip compression: iOS < 26")
            return nil
        }
        // Re-check availability at the API level — `appleFoundationModelsAvailable`
        // is a build-time gate; the device might still have AI
        // disabled by the user since the last check.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        default:
            logger.debug("Skip compression: SystemLanguageModel unavailable")
            return nil
        }

        let payload = excerpts.enumerated()
            .map { "--- Zdroj \($0.offset + 1) ---\n\($0.element)" }
            .joined(separator: "\n\n")

        let resolvedLanguage = language.resolved()
        let instructions = Self.instructions(language: resolvedLanguage)

        // Race AFM against the soft deadline. The `withTaskGroup`
        // pattern lets either branch win and cancels the loser —
        // critical because AFM's `respond` is async and we don't
        // want a stalled compute to keep ticking past the timeout.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: payload)
                    // Apple's response carries the assembled string
                    // as `.content`. We strip whitespace because the
                    // model occasionally adds leading/trailing
                    // newlines despite the instructions.
                    let summary = Self.responseText(response).trimmingCharacters(in: .whitespacesAndNewlines)
                    return summary.isEmpty ? nil : summary
                } catch {
                    Self.logger.info("AFM compression error: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
                Self.logger.info("AFM compression hit \(Self.timeoutSeconds) s soft timeout")
                return nil
            }
            let first = await group.next() ?? nil
            // Whoever finished second gets cancelled; we don't
            // need its value. The TaskGroup tears down cleanly
            // when this closure returns.
            group.cancelAll()
            return first
        }
        #else
        Self.logger.debug("Skip compression: FoundationModels not in build")
        return nil
        #endif
    }

    // MARK: - Helpers

    /// Instruction block pinned per language. Strict format demands:
    ///   * ONE paragraph, no bullets / preamble / commentary
    ///   * Match input language so prompt-injection paths stay
    ///     within the user's chosen locale (Czech / English here;
    ///     other locales fall through to English via
    ///     `AppLanguage.resolved`).
    ///   * Preserve names, numbers, dates, quoted strings verbatim —
    ///     these are the high-information tokens the smart model
    ///     will reason over. Lossy compression of "Adam pracuje
    ///     v Brně od roku 2023" into "Adam works somewhere"
    ///     defeats the purpose.
    ///   * Cap at ~200 words. Hard wall, not a soft target —
    ///     bypassing the cap means we no longer save prefill.
    nonisolated private static func instructions(language: AppLanguage) -> String {
        switch language {
        case .cs:
            return """
            Zhušťuješ referenční úryvky. Pravidla:
            - Vystup VŽDY v češtině.
            - Jeden odstavec, maximálně 200 slov.
            - Žádné odrážky, žádný úvod, žádný komentář, žádné nadpisy.
            - Jména, čísla, data a citáty zachovej doslovně.
            - Žádné dodatečné informace, nevykládej nad rámec textu.
            """
        case .en, .auto:
            return """
            You compress reference excerpts. Rules:
            - Output language MUST match the input.
            - One paragraph, maximum 200 words.
            - No bullets, no preamble, no commentary, no headings.
            - Preserve names, numbers, dates, quoted strings verbatim.
            - Do not add information beyond the source.
            """
        }
    }

    #if canImport(FoundationModels)
    /// Pull the response text out of Apple's wrapper. Mirrors the
    /// reflection-based extraction in
    /// `AppleFoundationModelsRuntime.string(from:)` because the
    /// snapshot type's shape is identical between
    /// `streamResponse(to:)` and `respond(to:)`. See the TODO on
    /// that helper for the iOS 26.x stability caveat. `nonisolated`
    /// because the TaskGroup child that calls it runs on the
    /// cooperative pool.
    @available(iOS 26.0, *)
    nonisolated private static func responseText<R>(_ response: R) -> String {
        if let s = response as? String { return s }
        let mirror = Mirror(reflecting: response)
        for child in mirror.children {
            if child.label == "content", let s = child.value as? String { return s }
        }
        return "\(response)"
    }
    #endif
}
