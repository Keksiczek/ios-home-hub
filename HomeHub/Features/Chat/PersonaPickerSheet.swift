import SwiftUI

struct PersonaPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsService
    
    // Columns for the grid
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Vyberte osobnost, která určuje, jak bude asistent odpovídat a chovat se.")
                        .font(HHTheme.body)
                        .foregroundStyle(HHTheme.textSecondary)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(settings.current.systemPromptPresets) { preset in
                            personaCard(for: preset)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 32)
            }
            .background(HHTheme.canvas.ignoresSafeArea())
            .navigationTitle("Osobnosti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zavřít") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func personaCard(for preset: SystemPromptPreset) -> some View {
        let isSelected = settings.current.activeSystemPromptPresetID == preset.id
        let color = Color(hex: preset.colorHex ?? "007AFF") ?? .blue
        
        Button {
            let id = preset.id
            Task {
                // Ensure atomic setting change
                await settings.set(\.activeSystemPromptPresetID, to: id)
                
                // Add tiny haptic pulse to confirm
                let generator = UIImpactFeedbackGenerator(style: .rigid)
                generator.impactOccurred()
                
                dismiss()
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.15))
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: preset.icon ?? "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(color)
                    }
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(HHTheme.accent)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.name)
                        .font(HHTheme.headline)
                        .foregroundStyle(HHTheme.textPrimary)
                    
                    if let desc = preset.shortDescription {
                        Text(desc)
                            .font(HHTheme.caption)
                            .foregroundStyle(HHTheme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                    .fill(isSelected ? HHTheme.accent.opacity(0.05) : HHTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                    .stroke(isSelected ? HHTheme.accent : HHTheme.stroke, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Add a quick Color(hex:) initializer if not exists (putting it right here or in a separate file)
extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
