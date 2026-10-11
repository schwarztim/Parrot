import Foundation
import Observation

/// Which main-window tab is showing, requests to switch, and the back
/// history. [UI]
///
/// AppState owns the one instance (`appState.navigation`); MainWindow binds
/// the sidebar selection to `selectedTab`, and the top bar's back button
/// calls `goBack()`.
@Observable
final class NavigationModel {

    /// Tabs the back history keeps.
    static let historyLimit = 50

    /// The tab MainWindow shows. Every change, from the sidebar or a
    /// request, records the tab it left.
    var selectedTab: SidebarTab = .home {
        didSet {
            guard selectedTab != oldValue, !isGoingBack else { return }
            history.append(oldValue)
            if history.count > Self.historyLimit {
                history.removeFirst(history.count - Self.historyLimit)
            }
        }
    }

    /// The segment ModelsLibraryView shows.
    var modelsSegment: ModelsLibrarySegment = .voice

    /// Tabs left behind, oldest first.
    private(set) var history: [SidebarTab] = []

    @ObservationIgnored private var isGoingBack = false

    var canGoBack: Bool { !history.isEmpty }

    /// Switches the main window to `tab`. Ignored for a tab that is not
    /// available yet.
    @MainActor
    func request(_ tab: SidebarTab) {
        guard tab.isAvailable else { return }
        selectedTab = tab
    }

    /// Returns to the previous tab, skipping tabs that are hidden now.
    @MainActor
    func goBack() {
        while let previous = history.popLast() {
            guard previous.isAvailable, previous != selectedTab else { continue }
            isGoingBack = true
            selectedTab = previous
            isGoingBack = false
            return
        }
    }
}
