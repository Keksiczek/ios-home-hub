import SwiftUI

struct WidgetData: Equatable {
    let type: String
    let label: String
    let value: String?
}

/// Parses special `<Widget:Type:Label:Value>` tags from model output
/// and renders native SwiftUI controls inline. Widget interactions
/// are routed to `WidgetActionHandler` for real HomeKit execution.
struct WidgetRenderer: View {
    let rawContent: String
    @EnvironmentObject private var actionHandler: WidgetActionHandler
    
    @State private var toggleStates: [String: Bool] = [:]
    @State private var sliderValues: [String: Double] = [:]
    @State private var actionFeedback: WidgetActionResult?
    
    var body: some View {
        let (cleanText, widgets) = parseWidgets(from: rawContent)
        
        VStack(alignment: .leading, spacing: HHTheme.spaceM) {
            if !cleanText.isEmpty {
                MarkdownContentView(content: cleanText, textColor: HHTheme.textPrimary)
            }
            
            if !widgets.isEmpty {
                VStack(spacing: HHTheme.spaceS) {
                    ForEach(widgets, id: \.label) { widget in
                        renderWidget(widget)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.top, 4)
            }
        }
        .overlay(alignment: .bottom) {
            if let feedback = actionFeedback {
                ActionFeedbackBanner(result: feedback)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                actionFeedback = nil
                            }
                        }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: actionFeedback?.id)
    }
    
    @ViewBuilder
    private func renderWidget(_ widget: WidgetData) -> some View {
        switch widget.type.lowercased() {
        case "toggle":
            let isOn = Binding(
                get: { self.toggleStates[widget.label] ?? (widget.value?.lowercased() == "on") },
                set: { newValue in
                    self.toggleStates[widget.label] = newValue
                    Task {
                        let result = await actionHandler.handleToggle(label: widget.label, isOn: newValue)
                        withAnimation { actionFeedback = result }
                        if !result.success {
                            // Revert on failure
                            self.toggleStates[widget.label] = !newValue
                        }
                    }
                }
            )
            
            HStack(spacing: HHTheme.spaceM) {
                Image(systemName: isOn.wrappedValue ? "lightbulb.fill" : "lightbulb.slash")
                    .font(.title3)
                    .foregroundStyle(isOn.wrappedValue ? HHTheme.accent : HHTheme.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
                
                Toggle(isOn: isOn) {
                    Text(widget.label)
                        .font(HHTheme.body)
                        .foregroundColor(HHTheme.textPrimary)
                }
                .tint(HHTheme.accent)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                    .stroke(HHTheme.stroke, lineWidth: 1)
            )
            
        case "slider", "brightness":
            let val = Binding(
                get: { self.sliderValues[widget.label] ?? (Double(widget.value ?? "50") ?? 50) },
                set: { newValue in
                    self.sliderValues[widget.label] = newValue
                }
            )
            
            VStack(spacing: HHTheme.spaceS) {
                HStack {
                    Image(systemName: "sun.min")
                        .foregroundStyle(HHTheme.textSecondary)
                    Text(widget.label)
                        .font(HHTheme.body)
                    Spacer()
                    Text("\(Int(val.wrappedValue))%")
                        .font(HHTheme.subheadline)
                        .foregroundStyle(HHTheme.accent)
                        .monospacedDigit()
                }
                Slider(value: val, in: 0...100, step: 1) {
                    Text(widget.label)
                } onEditingChanged: { editing in
                    if !editing {
                        Task {
                            let result = await actionHandler.handleSlider(label: widget.label, value: val.wrappedValue)
                            withAnimation { actionFeedback = result }
                        }
                    }
                }
                .tint(HHTheme.accent)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                    .stroke(HHTheme.stroke, lineWidth: 1)
            )
            
        case "thermometer", "gauge":
            let val = Double(widget.value ?? "0") ?? 0
            VStack {
                HStack {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(temperatureColor(for: val))
                        .symbolEffect(.pulse, options: .speed(0.3))
                    Text(widget.label)
                        .font(HHTheme.body)
                    Spacer()
                    Text(String(format: "%.1f°C", val))
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(temperatureColor(for: val))
                }
                Gauge(value: val, in: 0...40) {
                    Text("°C")
                }
                .gaugeStyle(.linearCapacity)
                .tint(Gradient(colors: [.blue, .cyan, .green, .yellow, .orange, .red]))
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HHTheme.cornerLarge, style: .continuous)
                    .stroke(HHTheme.stroke, lineWidth: 1)
            )
            
        default:
            // Fallback for unknown widgets
            HStack {
                Image(systemName: "exclamationmark.square")
                Text("Neznámý widget: \(widget.label)")
            }
            .padding()
            .background(HHTheme.warning.opacity(0.2))
            .cornerRadius(HHTheme.cornerLarge)
        }
    }
    
    private func temperatureColor(for value: Double) -> Color {
        switch value {
        case ..<15: return .blue
        case 15..<22: return .green
        case 22..<28: return .orange
        default: return .red
        }
    }
    
    private func parseWidgets(from text: String) -> (String, [WidgetData]) {
        var plainText = text
        var widgets: [WidgetData] = []
        
        // Regex to match <Widget:Type:Label[:Value]>
        let pattern = "<Widget:([^:]+):([^:>]+)(?::([^>]*))?>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [])
        }
        
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        
        for match in matches.reversed() { // reverse to preserve ranges during replacement
            let type = nsString.substring(with: match.range(at: 1))
            let label = nsString.substring(with: match.range(at: 2))
            let valueRange = match.range(at: 3)
            let value = valueRange.location != NSNotFound ? nsString.substring(with: valueRange) : nil
            
            widgets.insert(WidgetData(type: type, label: label, value: value), at: 0)
            
            // Remove the widget tag from the plain text
            plainText = (plainText as NSString).replacingCharacters(in: match.range, with: "")
        }
        
        return (plainText.trimmingCharacters(in: .whitespacesAndNewlines), widgets)
    }
}

// MARK: - Action Feedback Banner

private struct ActionFeedbackBanner: View {
    let result: WidgetActionResult
    
    var body: some View {
        HStack(spacing: HHTheme.spaceS) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? HHTheme.success : HHTheme.danger)
            Text(result.message)
                .font(HHTheme.callout)
                .foregroundStyle(HHTheme.textPrimary)
        }
        .padding(.horizontal, HHTheme.spaceL)
        .padding(.vertical, HHTheme.spaceM)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
        .padding(.bottom, HHTheme.spaceL)
    }
}
