import Foundation
import SwiftUI

/// Action result for widget-triggered commands. Propagated back to
/// the UI so the bubble can show a confirmation or error toast.
struct WidgetActionResult: Identifiable {
    let id = UUID()
    let widgetLabel: String
    let success: Bool
    let message: String
}

/// Protocol for handling widget-triggered actions in the chat.
/// Decouples the WidgetRenderer from specific service implementations.
protocol WidgetActionHandling: AnyObject {
    func handleToggle(label: String, isOn: Bool) async -> WidgetActionResult
    func handleSlider(label: String, value: Double) async -> WidgetActionResult
}

/// JSON payload understood by `HomeKitSkill.applyChanges`.
///
/// Encoded via `JSONEncoder` so we never hand-format the wire string
/// (the previous approach silently broke when an accessory name
/// contained a quote, backslash, or non-ASCII character).
private struct HomeKitToggleArgs: Encodable {
    let accessoryName: String
    let characteristic: String
    let value: HomeKitValue

    /// Mixed-type union — `powerState` is `Bool`, `brightness` is `Int`.
    /// `Encodable` conformance is hand-written so the JSON output uses
    /// the bare boolean / number form HomeKitSkill expects.
    enum HomeKitValue: Encodable {
        case bool(Bool)
        case int(Int)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try container.encode(value)
            case .int(let value):  try container.encode(value)
            }
        }
    }
}

/// Production implementation: routes widget actions through the
/// SkillManager → HomeKitSkill pipeline so toggles and sliders
/// actually control real HomeKit accessories.
@MainActor
final class WidgetActionHandler: ObservableObject, WidgetActionHandling {
    @Published var lastResult: WidgetActionResult?

    func handleToggle(label: String, isOn: Bool) async -> WidgetActionResult {
        let args = HomeKitToggleArgs(
            accessoryName: label,
            characteristic: "powerState",
            value: .bool(isOn)
        )
        let successMessage = "\(label) \(isOn ? "zapnuto" : "vypnuto")"
        return await execute(args: args, label: label, successMessage: successMessage)
    }

    func handleSlider(label: String, value: Double) async -> WidgetActionResult {
        let percent = Int(value)
        let args = HomeKitToggleArgs(
            accessoryName: label,
            characteristic: "brightness",
            value: .int(percent)
        )
        let successMessage = "\(label) nastaveno na \(percent)%"
        return await execute(args: args, label: label, successMessage: successMessage)
    }

    // MARK: - Shared execution path

    /// Encodes `args`, dispatches through `SkillManager.executeThrowing`,
    /// and maps success / failure to a `WidgetActionResult`. Any encoding
    /// or skill error becomes a non-success result with the localised
    /// error description as the user-visible message.
    private func execute(
        args: HomeKitToggleArgs,
        label: String,
        successMessage: String
    ) async -> WidgetActionResult {
        let command: ActionCommand
        do {
            command = try makeCommand(for: args)
        } catch {
            return finalize(label: label, success: false, message: error.localizedDescription)
        }

        do {
            _ = try await SkillManager.shared.executeThrowing(command)
            return finalize(label: label, success: true, message: successMessage)
        } catch {
            return finalize(label: label, success: false, message: error.localizedDescription)
        }
    }

    private func makeCommand(for args: HomeKitToggleArgs) throws -> ActionCommand {
        let argsJSON = try JSONEncoder().encode(args)
        guard let argsString = String(data: argsJSON, encoding: .utf8) else {
            throw WidgetActionError.encodingFailed
        }
        let envelope = ToolCallEnvelope(name: "HomeKitSearch", input: argsString)
        return envelope.toActionCommand()
    }

    private func finalize(label: String, success: Bool, message: String) -> WidgetActionResult {
        let result = WidgetActionResult(widgetLabel: label, success: success, message: message)
        lastResult = result
        HHHaptics.notification(success ? .success : .error, enabled: true)
        return result
    }
}

private enum WidgetActionError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Nepodařilo se zakódovat povel pro HomeKit."
        }
    }
}
