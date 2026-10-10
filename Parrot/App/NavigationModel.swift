import Foundation
import Observation

/// Which main-window tab is showing, and requests to switch. [UI]
///
/// AppState owns the one instance (`appState.navigation`); MainWindow binds
/// the sidebar selection to `selectedTab`.
@Observable
final class NavigationModel {

    /// The tab MainWindow shows.
    var selectedTab: SidebarTab = .home

    /// The segment ModelsLibraryView shows.
    var modelsSegment: ModelsLibrarySegment = .voice

    /// Switches the main window to `tab`. Ignored for a tab that is not
    /// available yet.
    @MainActor
    func request(_ tab: SidebarTab) {
        guard tab.isAvailable else { return }
        selectedTab = tab
    }
}
