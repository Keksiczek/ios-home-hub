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

    func publish(_ report: PromptBudgetReport) {
        lastReport = report
    }
}
