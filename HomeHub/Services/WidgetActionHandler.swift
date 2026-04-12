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

/// Production implementation: routes widget actions through the
/// SkillManager → HomeKitSkill pipeline so toggles and sliders
/// actually control real HomeKit accessories.
@MainActor
final class WidgetActionHandler: ObservableObject, WidgetActionHandling {
    @Published var lastResult: WidgetActionResult?
    
    func handleToggle(label: String, isOn: Bool) async -> WidgetActionResult {
        // Build a HomeKit action JSON the same format HomeKitSkill expects.
        let json = """
        {"accessoryName": "\(label)", "characteristic": "powerState", "value": \(isOn)}
        """
        
        let command = ActionCommand(
            skillName: "HomeKitSearch",
            input: json,
            fullTag: "<Action:HomeKitSearch:\(json)>"
        )
        
        let output = await SkillManager.shared.execute(command)
        let success = output.lowercased().contains("úspěch")
        let result = WidgetActionResult(
            widgetLabel: label,
            success: success,
            message: success ? "\(label) \(isOn ? "zapnuto" : "vypnuto")" : output
        )
        lastResult = result
        HHHaptics.notification(success ? .success : .error, enabled: true)
        return result
    }
    
    func handleSlider(label: String, value: Double) async -> WidgetActionResult {
        let json = """
        {"accessoryName": "\(label)", "characteristic": "brightness", "value": \(Int(value))}
        """
        
        let command = ActionCommand(
            skillName: "HomeKitSearch",
            input: json,
            fullTag: "<Action:HomeKitSearch:\(json)>"
        )
        
        let output = await SkillManager.shared.execute(command)
        let success = output.lowercased().contains("úspěch")
        let result = WidgetActionResult(
            widgetLabel: label,
            success: success,
            message: success ? "\(label) nastaveno na \(Int(value))%" : output
        )
        lastResult = result
        HHHaptics.notification(success ? .success : .error, enabled: true)
        return result
    }
}
