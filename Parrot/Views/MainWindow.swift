import SwiftUI

// MARK: - Main Window

/// The settings window: a sidebar of tabs and the selected tab's view.
/// Frozen. Tab order and availability live in SidebarTab; the selection
/// lives in `appState.navigation`.
struct MainWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var navigation = appState.navigation

        NavigationSplitView {
            List(SidebarTab.visibleCases, selection: $navigation.selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailContent(for: navigation.selectedTab)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 500)
    }

    // MARK: - Detail Content

    @ViewBuilder
    private func detailContent(for tab: SidebarTab) -> some View {
        switch tab {
        case .home:
            HomeView()
        case .modes:
            ModesView()
        case .vocabulary:
            VocabularyView()
        case .history:
            HistoryView()
        case .models:
            ModelsLibraryView()
        case .sound:
            SoundView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .textInput:
            OutputSettingsView()
        case .general:
            GeneralSettingsView()
        case .advanced:
            AdvancedSettingsView()
        case .agents:
            AgentsSettingsView()
        case .importer:
            ImportView()
        }
    }
}

#Preview {
    MainWindow()
        .environment(AppState())
}
