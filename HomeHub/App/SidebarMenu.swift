import SwiftUI

// MARK: - Environment plumbing

/// Closure that opens the phone-layout sidebar menu. Provided by
/// `MainTabView` via environment so every destination's toolbar can
/// wire up the hamburger button without holding a binding directly.
private struct ShowSidebarMenuKey: EnvironmentKey {
    static let defaultValue: @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var showSidebarMenu: @Sendable () -> Void {
        get { self[ShowSidebarMenuKey.self] }
        set { self[ShowSidebarMenuKey.self] = newValue }
    }
}

// MARK: - Toolbar button

/// Standard hamburger button bound to `@Environment(\.showSidebarMenu)`.
/// Automatically hides on regular-width layouts where the sidebar is
/// already visible via `NavigationSplitView`.
///
/// The symbol + accessibility label are centralised here so every
/// destination's toolbar gets the exact same button.
struct SidebarMenuButton: View {
    @Environment(\.showSidebarMenu) private var showMenu
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        if hSize != .regular {
            Button {
                showMenu()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.body.weight(.medium))
            }
            .accessibilityLabel("Menu")
            .accessibilityHint("Přepnutí mezi sekcemi aplikace")
        }
    }
}

// MARK: - Sidebar sheet

/// Sheet-style sidebar menu shown on iPhone / compact-width layouts.
/// Lists every `MainTab` so the user can switch destinations without a
/// permanent tab bar.
struct SidebarMenuView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var memory: MemoryService
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
                            rowContent(for: tab)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            appState.selectedTab == tab
                                ? HHTheme.accentSoft
                                : Color(.secondarySystemGroupedBackground)
                        )
                    }
                } header: {
                    header
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Zavřít") { dismiss() }
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HomeHub")
                .font(HHTheme.title2)
                .foregroundStyle(HHTheme.textPrimary)
            Text(activeModelSubtitle)
                .font(HHTheme.footnote)
                .foregroundStyle(HHTheme.textSecondary)
        }
        .padding(.vertical, HHTheme.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeModelSubtitle: String {
        if let model = runtime.activeModel {
            return model.displayName
        }
        switch runtime.state {
        case .loading(let id): return "Načítám \(id)…"
        case .failed:          return "Žádný model — viz Diagnostika"
        default:               return "Žádný model nenačten"
        }
    }

    @ViewBuilder
    private func rowContent(for tab: MainTab) -> some View {
        let isActive = appState.selectedTab == tab
        HStack(spacing: HHTheme.spaceL) {
            Image(systemName: tab.symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(isActive ? HHTheme.accent : HHTheme.textSecondary)
            Text(tab.title)
                .font(HHTheme.headline)
                .foregroundStyle(HHTheme.textPrimary)
            Spacer()
            // Per-tab pending-review badge. Memory tab surfaces the
            // count of candidates AND auto-episodes awaiting approval
            // — both the manual extraction flow and the new background
            // episode write-back land here, so the user sees one
            // unified "you have N things to review" number instead of
            // discovering pending episodes only by opening the tab.
            if tab == .memory {
                let count = pendingReviewCount
                if count > 0 {
                    Text("\(count)")
                        .font(HHTheme.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(HHTheme.accent))
                        .foregroundStyle(.white)
                        .accessibilityLabel("\(count) položek k revizi")
                }
            }
            if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(HHTheme.accent)
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Sum of memory-review queues: extraction candidates plus
    /// pending (not-yet-approved) auto-episodes. Both flows land in
    /// the Memory tab's review pile, so showing them as one number
    /// matches what the user actually does there ("clear the queue").
    private var pendingReviewCount: Int {
        memory.candidates.count + memory.episodes.filter { !$0.approved }.count
    }
}
