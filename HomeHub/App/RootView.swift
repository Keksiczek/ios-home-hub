import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            HHTheme.canvas.ignoresSafeArea()

            switch appState.phase {
            case .launching:
                LaunchView()
                    .transition(.opacity)
            case .onboarding:
                OnboardingFlowView()
                    .transition(.opacity)
            case .ready:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.phase)
        .task {
            await container.bootstrap()
        }
    }
}

struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(HHTheme.accent)
            Text("HomeHub")
                .font(HHTheme.title)
            ProgressView()
                .controlSize(.small)
                .padding(.top, 8)
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppContainer.preview())
        .environmentObject(AppContainer.preview().appState)
}
