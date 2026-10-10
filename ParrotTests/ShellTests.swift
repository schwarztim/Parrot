import AppKit
import XCTest

@testable import Parrot

/// The app shell without a GUI: which sidebar tabs show, tab requests, and
/// the status menu's items. Showing the status item and windows needs a
/// logged-in GUI session and is not covered here.
@MainActor
final class ShellTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "ShellTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeContext(onboarded: Bool) -> MenuContext {
        let settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        settings.general.hasCompletedOnboarding = onboarded
        let vocabulary = VocabularyManager(storageURL: directory.appendingPathComponent("vocabulary.json"))
        let state = AppState(vocabularyManager: vocabulary)
        state.settings = settings
        return MenuContext(appState: state, settings: settings, windows: WindowManager(appState: state, appSettings: settings))
    }

    // MARK: - Sidebar

    func testExistingTabsStayVisible() {
        let visible = SidebarTab.visibleCases
        for tab in [SidebarTab.home, .modes, .vocabulary, .history, .models, .sound, .shortcuts, .general] {
            XCTAssertTrue(visible.contains(tab), "\(tab) should be visible")
        }
        XCTAssertEqual(visible, SidebarTab.allCases.filter(\.isAvailable))
    }

    func testRequestSwitchesOnlyToAvailableTabs() {
        let navigation = NavigationModel()
        navigation.request(.models)
        XCTAssertEqual(navigation.selectedTab, .models)

        if let hidden = SidebarTab.allCases.first(where: { !$0.isAvailable }) {
            navigation.request(hidden)
            XCTAssertEqual(navigation.selectedTab, .models)
        }
    }

    // MARK: - Status Menu

    func testMenuHasStatusOpenVersionAndQuit() {
        let menu = NSMenu()
        MenuLayout.populate(menu, context: makeContext(onboarded: false))
        let titles = menu.items.map(\.title)

        XCTAssertEqual(titles.first, "Ready")
        XCTAssertTrue(titles.contains("Open Parrot..."))
        XCTAssertEqual(titles.last, "Quit Parrot")
        XCTAssertTrue(titles[titles.count - 2].hasPrefix("Parrot "), "version item before Quit")
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
        XCTAssertEqual(menu.items.first { $0.title == "Open Parrot..." }?.keyEquivalent, ",")
        // No permission rows during onboarding.
        XCTAssertFalse(titles.contains { $0.contains("grant") })
    }

    func testPermissionRowsShowAfterOnboarding() {
        let context = makeContext(onboarded: true)
        let menu = NSMenu()
        MenuLayout.populate(menu, context: context)
        let titles = menu.items.map(\.title)

        let expected = context.appState.permissionWarnings.map(\.message)
        XCTAssertFalse(expected.isEmpty, "a fresh AppState has no permissions granted")
        for message in expected {
            XCTAssertTrue(titles.contains(message), "missing row: \(message)")
        }
    }

    func testActionMenuItemRunsItsHandler() {
        var ran = false
        let item = ActionMenuItem(title: "Run") { ran = true }
        XCTAssertTrue(item.target === item)
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        XCTAssertTrue(ran)
    }
}
