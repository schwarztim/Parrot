import SwiftUI

// MARK: - Sidebar Tab

enum SidebarTab: String, CaseIterable, Identifiable {
    case home
    case modes
    case vocabulary
    case configuration
    case sound
    case models

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .modes: return "Modes"
        case .vocabulary: return "Vocabulary"
        case .configuration: return "Configuration"
        case .sound: return "Sound"
        case .models: return "Models"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .modes: return "slider.horizontal.3"
        case .vocabulary: return "text.book.closed"
        case .configuration: return "gearshape"
        case .sound: return "speaker.wave.2"
        case .models: return "cpu"
        }
    }
}

// MARK: - Main Window

struct MainWindow: View {
    @State private var selectedTab: SidebarTab = .home
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 500)
        .onChange(of: appState.requestConfigurationTab) { _, requested in
            if requested {
                selectedTab = .configuration
                appState.requestConfigurationTab = false
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(SidebarTab.allCases, selection: $selectedTab) { tab in
            Label(tab.label, systemImage: tab.icon)
                .tag(tab)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .home:
            HomeView()
        case .modes:
            ModesView()
        case .vocabulary:
            VocabularyView()
        case .configuration:
            ConfigurationView()
        case .sound:
            SoundView()
        case .models:
            ModelsView()
        }
    }
}

#Preview {
    MainWindow()
        .environment(AppState())
}
