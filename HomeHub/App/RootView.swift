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
        // Note: `bootstrap()` already calls `autoLoadSelectedModel()`
        // immediately after flipping `appState.phase` to `.ready`, and
        // the scene-phase `.active` path covers reload-after-background.
        // The historic `onChange(of: phase)` trigger here ran a duplicate
        // load via the view-body update path; the crash report
        // `HomeHub-2026-05-15-220849.ips` showed the watchdog killing
        // the app inside that second call when iOS tried to suspend the
        // app mid-load. Removed to keep autoload on the bootstrap path
        // only, which has the crash-loop guard wired up.
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
