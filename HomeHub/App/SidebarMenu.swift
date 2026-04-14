import SwiftUI

// MARK: - Environment plumbing

/// Closure that opens the phone-layout sidebar menu. Provided by
/// `MainTabView` via environment so every destination's toolbar can
/// wire up the hamburger button without holding a binding directly.
private struct ShowSidebarMenuKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var showSidebarMenu: () -> Void {
        get { self[ShowSidebarMenuKey.self] }
        set { self[ShowSidebarMenuKey.self] = newValue }
    }
}

// MARK: - Toolbar button

/// Standard hamburger button bound to `@Environment(\.showSidebarMenu)`.
/// Automatically hides on regular-width layouts where the sidebar is
/// already visible via `NavigationSplitView`.
struct SidebarMenuButton: View {
    @Environment(\.showSidebarMenu) private var showMenu
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        if hSize != .regular {
            Button {
                showMenu()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .accessibilityLabel("Menu")
        }
    }
}

// MARK: - Sidebar sheet

/// Sheet-style sidebar menu shown on iPhone / compact-width layouts.
/// Lists every `MainTab` so the user can switch destinations without a
/// permanent tab bar.
struct SidebarMenuView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let onSelect: (MainTab) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(MainTab.allCases) { tab in
                        Button {
                            onSelect(tab)
                        } label: {
                            HStack(spacing: HHTheme.spaceL) {
                                Image(systemName: tab.symbol)
                                    .font(.title3)
                                    .frame(width: 28)
                                    .foregroundStyle(appState.selectedTab == tab ? HHTheme.accent : HHTheme.textSecondary)
                                Text(tab.title)
                                    .font(HHTheme.headline)
                                    .foregroundStyle(HHTheme.textPrimary)
                                Spacer()
                                if appState.selectedTab == tab {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(HHTheme.accent)
                                        .font(.callout.weight(.semibold))
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("HomeHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
