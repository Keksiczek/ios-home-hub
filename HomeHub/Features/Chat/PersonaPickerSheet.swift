import SwiftUI

struct PersonaPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsService
    
    // Columns for the grid
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    private var builtInPresets: [SystemPromptPreset] {
        settings.current.systemPromptPresets.filter { $0.isBuiltIn }
    }

    private var customPresets: [SystemPromptPreset] {
        settings.current.systemPromptPresets.filter { !$0.isBuiltIn }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Vyberte osobnost, která určuje, jak bude asistent odpovídat a chovat se.")
                        .font(HHTheme.body)
                        .foregroundStyle(HHTheme.textSecondary)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    section(title: "Vestavěné", presets: builtInPresets)

                    customSection
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
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SystemPromptManagerView()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Spravovat osobnosti")
                }
            }
        }
    }

    @ViewBuilder
    private func section(title: String, presets: [SystemPromptPreset]) -> some View {
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(HHTheme.caption.weight(.semibold))
                    .foregroundStyle(HHTheme.textSecondary)
                    .textCase(.uppercase)
                    .padding(.horizontal)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(presets) { preset in
                        personaCard(for: preset)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var customSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vlastní")
                .font(HHTheme.caption.weight(.semibold))
                .foregroundStyle(HHTheme.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal)

            if customPresets.isEmpty {
                NavigationLink {
                    SystemPromptManagerView()
                } label: {
                    HStack(spacing: HHTheme.spaceM) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(HHTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vytvořit vlastní osobnost")
                                .font(HHTheme.subheadline.weight(.medium))
                                .foregroundStyle(HHTheme.textPrimary)
                            Text("Definuj si vlastní systémový prompt.")
                                .font(HHTheme.caption)
                                .foregroundStyle(HHTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(HHTheme.textSecondary.opacity(0.5))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                            .fill(HHTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                            .stroke(HHTheme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(customPresets) { preset in
                        personaCard(for: preset)
                    }
                }
                .padding(.horizontal)
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
