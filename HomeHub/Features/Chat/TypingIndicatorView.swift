import SwiftUI

/// Premium animated typing indicator shown when the AI is processing but
/// the first token hasn't arrived yet.
struct TypingIndicatorView: View {
    @State private var pulse = false
    
    var body: some View {
        HStack(spacing: HHTheme.spaceM) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(HHTheme.accent)
                .rotationEffect(.degrees(pulse ? 10 : -10))
            
            HStack(spacing: 4) {
                Circle()
                    .fill(HHTheme.textSecondary)
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(0.0), value: pulse)
                
                Circle()
                    .fill(HHTheme.textSecondary)
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(0.2), value: pulse)
                
                Circle()
                    .fill(HHTheme.textSecondary)
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(0.4), value: pulse)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: HHTheme.cornerMedium, style: .continuous)
                .fill(HHTheme.surface)
                .shadow(color: Color.black.opacity(0.05), radius: 3, y: 1)
        )
        .onAppear {
            pulse = true
        }
    }
}
