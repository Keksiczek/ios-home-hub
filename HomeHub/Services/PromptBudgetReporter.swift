import Foundation
import SwiftUI

/// Observable wrapper that holds the most recent `PromptBudgetReport`
/// emitted by `PromptAssemblyService`.
///
/// Split out so `PromptAssemblyService` itself can stay a plain
/// `@MainActor final class` without inheriting the publisher overhead
/// of `ObservableObject`. The Developer Diagnostics view observes this
/// reporter directly via `@EnvironmentObject`.
@MainActor
final class PromptBudgetReporter: ObservableObject {

    /// Budget report from the most recent `PromptAssemblyService.build(from:)` call.
    @Published private(set) var lastReport: PromptBudgetReport?

    /// Real-tokenizer ground-truth count for the most recent prompt,
    /// or `nil` when no MLX model was loaded at assembly time. Used by
    /// Developer Diagnostics to surface the drift between the
    /// heuristic and reality — repeated large drifts indicate the
    /// per-family `messageTokenOverhead` calibration needs revisiting.
    @Published private(set) var lastRealTokenCount: Int?
    /// Wall-clock timestamp of the last `recordRealTokenCount` so the
    /// diagnostics view can hide stale values if a newer report has
    /// landed but the real count is still being computed.
    @Published private(set) var lastRealTokenCountAt: Date?

    func publish(_ report: PromptBudgetReport) {
        lastReport = report
        // The real-token count is computed async by the caller and
        // recorded separately; clear the previous value so the UI
        // doesn't render a stale "real=920" next to a fresh
        // "heuristic=120" prompt.
        lastRealTokenCount = nil
        lastRealTokenCountAt = nil
    }

    /// Records the real tokenizer count for the most recent prompt.
    /// Called from `ConversationService.performSend` after the prompt
    /// has been built and (optionally) sent through the runtime
    /// tokenizer for ground-truth comparison.
    func recordRealTokenCount(_ count: Int) {
        lastRealTokenCount = count
        lastRealTokenCountAt = .now
    }

    /// Percent drift of the heuristic estimate from the real count.
    /// Positive = heuristic over-counted (safer); negative = under-
    /// counted (risk of budget overrun). `nil` when either value is
    /// missing. Used as the headline number in Diagnostics.
    var heuristicDriftPercent: Double? {
        guard let report = lastReport,
              let real = lastRealTokenCount,
              real > 0 else { return nil }
        let heuristic = Double(report.totalPromptTokens)
        return (heuristic - Double(real)) / Double(real) * 100
    }
}
