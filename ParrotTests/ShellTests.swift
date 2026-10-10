import AppKit
import XCTest

@testable import Parrot

/// The app shell without a GUI: which sidebar tabs show, tab requests, the
/// status menu's items, the status icon's states and frames, UI settings
/// and the quick start labels. Showing the status item and windows needs a
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

    func testMenuHasToggleStatusWindowsVersionAndQuit() {
        let menu = NSMenu()
        MenuLayout.populate(menu, context: makeContext(onboarded: false))
        let titles = menu.items.map(\.title)

        XCTAssertEqual(Array(titles.prefix(2)), ["Start Recording", "Ready"])
        XCTAssertTrue(menu.items[0].isEnabled)
        XCTAssertFalse(menu.items[1].isEnabled, "the status row is a label")
        XCTAssertTrue(titles.contains("History..."))
        XCTAssertTrue(titles.contains("Settings..."))
        XCTAssertLessThan(titles.firstIndex(of: "History...")!, titles.firstIndex(of: "Settings...")!)
        XCTAssertEqual(titles.last, "Quit Parrot")
        XCTAssertTrue(titles[titles.count - 2].hasPrefix("Parrot "), "version item before Quit")
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
        XCTAssertEqual(menu.items.first { $0.title == "Settings..." }?.keyEquivalent, ",")
        // No permission rows during onboarding.
        XCTAssertFalse(titles.contains { $0.contains("grant") })
    }

    // MARK: - Status Icon

    func testStatusIconFollowsThePhase() {
        XCTAssertEqual(StatusIconState.resolve(phase: .idle, status: .idle, isCompleting: false), .ready)
        XCTAssertEqual(StatusIconState.resolve(phase: .starting, status: .idle, isCompleting: false), .recording)
        XCTAssertEqual(StatusIconState.resolve(phase: .recording, status: .recording, isCompleting: false), .recording)
        XCTAssertEqual(StatusIconState.resolve(phase: .stopping, status: .recording, isCompleting: false), .working)
        XCTAssertEqual(StatusIconState.resolve(phase: .processing, status: .processing, isCompleting: false), .working)
    }

    func testStatusIconLoadingAndComplete() {
        XCTAssertEqual(StatusIconState.resolve(phase: .idle, status: .downloading(0.4), isCompleting: false), .loading)
        XCTAssertEqual(StatusIconState.resolve(phase: .idle, status: .idle, isCompleting: true), .complete)
        XCTAssertEqual(StatusIconState.resolve(phase: .idle, status: .error("x"), isCompleting: false), .ready)
        // A recording in progress wins over a download or a stale complete.
        XCTAssertEqual(StatusIconState.resolve(phase: .recording, status: .downloading(0.4), isCompleting: true), .recording)
    }

    func testOnlyRecordingAndWorkingAnimate() {
        XCTAssertTrue(StatusIconState.recording.isAnimated)
        XCTAssertTrue(StatusIconState.working.isAnimated)
        XCTAssertFalse(StatusIconState.ready.isAnimated)
        XCTAssertFalse(StatusIconState.loading.isAnimated)
        XCTAssertFalse(StatusIconState.complete.isAnimated)
    }

    func testIconFramesCycleAndRiseWithLevel() {
        XCTAssertEqual(StatusIconFrames.interval, 0.025)
        let quiet = StatusIconFrames.recordingBars(frame: 3, level: 0)
        let loud = StatusIconFrames.recordingBars(frame: 3, level: 1)
        XCTAssertEqual(quiet.count, 5)
        for (low, high) in zip(quiet, loud) {
            XCTAssertGreaterThan(high, low)
            XCTAssertLessThanOrEqual(high, 1)
            XCTAssertGreaterThan(low, 0)
        }
        XCTAssertEqual(
            StatusIconFrames.recordingBars(frame: 3, level: 0.5),
            StatusIconFrames.recordingBars(frame: 3 + StatusIconFrames.cycle, level: 0.5)
        )
        XCTAssertNotEqual(StatusIconFrames.recordingBars(frame: 0, level: 0), StatusIconFrames.recordingBars(frame: 10, level: 0))

        let dots = StatusIconFrames.workingDots(frame: 5)
        XCTAssertEqual(dots.count, 3)
        XCTAssertTrue(dots.allSatisfy { $0 >= 0.3 && $0 <= 1 })
        XCTAssertNotEqual(StatusIconFrames.workingDots(frame: 0), StatusIconFrames.workingDots(frame: 20))
    }

    func testIconImagesAreTemplates() {
        for state in [StatusIconState.loading, .ready, .recording, .working, .complete] {
            let image = StatusIconFrames.image(for: state, frame: 7, level: 0.3, needsAttention: false)
            XCTAssertNotNil(image, "\(state)")
            XCTAssertEqual(image?.isTemplate, true, "\(state)")
        }
    }

    // MARK: - Back History

    func testBackWalksTheTabHistory() {
        let navigation = NavigationModel()
        XCTAssertFalse(navigation.canGoBack)
        navigation.request(.models)
        navigation.request(.sound)
        // A sidebar click writes the selection directly.
        navigation.selectedTab = .general
        XCTAssertEqual(navigation.history, [.home, .models, .sound])

        navigation.goBack()
        XCTAssertEqual(navigation.selectedTab, .sound)
        navigation.goBack()
        XCTAssertEqual(navigation.selectedTab, .models)
        navigation.goBack()
        XCTAssertEqual(navigation.selectedTab, .home)
        XCTAssertFalse(navigation.canGoBack)
        navigation.goBack()
        XCTAssertEqual(navigation.selectedTab, .home)
    }

    func testBackSkipsHiddenTabsAndHistoryIsCapped() {
        let navigation = NavigationModel()
        navigation.request(.home)
        XCTAssertTrue(navigation.history.isEmpty, "re-selecting the same tab adds nothing")

        if let hidden = SidebarTab.allCases.first(where: { !$0.isAvailable }) {
            navigation.selectedTab = .models
            navigation.selectedTab = hidden
            navigation.selectedTab = .sound
            navigation.goBack()
            XCTAssertEqual(navigation.selectedTab, .models)
        }

        for index in 0..<120 {
            navigation.selectedTab = index.isMultiple(of: 2) ? .models : .sound
        }
        XCTAssertEqual(navigation.history.count, NavigationModel.historyLimit)
    }

    // MARK: - Tips, Warnings, Tooltips

    func testFirstRunToastsHideWhenDismissedOrSatisfied() {
        let home = FirstRunToasts.visible(on: .home, dismissed: [], satisfied: [])
        XCTAssertEqual(home.map(\.id), ["home.firstDictation", "home.typingTest", "home.miniRecorder"])

        let dismissed = FirstRunToasts.dismissing("home.typingTest", from: [])
        XCTAssertEqual(
            FirstRunToasts.visible(on: .home, dismissed: dismissed, satisfied: ["home.firstDictation"]).map(\.id),
            ["home.miniRecorder"]
        )
        XCTAssertEqual(
            FirstRunToasts.visible(on: .modes, dismissed: [], satisfied: []).map(\.id),
            ["modes.create", "modes.activation", "modes.shortcut"]
        )
        XCTAssertEqual(Set(FirstRunToasts.catalog.map(\.id)).count, FirstRunToasts.catalog.count, "ids are unique")
    }

    func testDismissedToastsPersist() {
        let settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        settings.general.dismissedToasts = FirstRunToasts.dismissing("modes.create", from: settings.general.dismissedToasts)
        let reloaded = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertEqual(reloaded.general.dismissedToasts, ["modes.create"])
        XCTAssertEqual(FirstRunToasts.visible(on: .modes, dismissed: reloaded.general.dismissedToasts, satisfied: []).count, 2)
    }

    func testPermissionsRequiredWarning() {
        let warning = WarningState.permissionsRequired(missing: ["Microphone", "Accessibility"])
        XCTAssertEqual(warning.title, "Permissions Required")
        XCTAssertEqual(warning.primaryTitle, "Continue Anyway")
        XCTAssertNotNil(warning.secondaryTitle)
        XCTAssertTrue(warning.message.contains("Microphone and Accessibility"))
        XCTAssertEqual(WarningState.lidClosed.primaryTitle, "Choose Another")
    }

    func testTooltipWarmthAndPlacement() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(TooltipLogic.delay(now: now, isShowing: false, lastHiddenAt: nil), TooltipLogic.showDelay)
        XCTAssertEqual(TooltipLogic.delay(now: now, isShowing: true, lastHiddenAt: nil), 0)
        XCTAssertEqual(TooltipLogic.delay(now: now, isShowing: false, lastHiddenAt: now.addingTimeInterval(-0.5)), 0)
        XCTAssertEqual(TooltipLogic.delay(now: now, isShowing: false, lastHiddenAt: now.addingTimeInterval(-2)), TooltipLogic.showDelay)

        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 100, height: 40)
        let anchor = CGRect(x: 450, y: 400, width: 100, height: 20)
        XCTAssertEqual(TooltipLogic.origin(anchor: anchor, size: size, placement: .above, screen: screen), CGPoint(x: 450, y: 426))
        XCTAssertEqual(TooltipLogic.origin(anchor: anchor, size: size, placement: .leading, screen: screen), CGPoint(x: 344, y: 390))
        XCTAssertEqual(TooltipLogic.origin(anchor: anchor, size: size, placement: .trailing, screen: screen), CGPoint(x: 556, y: 390))
        // Near the top edge, "above" flips below the trigger.
        let top = CGRect(x: 450, y: 770, width: 100, height: 20)
        XCTAssertEqual(TooltipLogic.origin(anchor: top, size: size, placement: .above, screen: screen), CGPoint(x: 450, y: 724))
        // At the left edge, "leading" flips to the trailing side.
        let left = CGRect(x: 10, y: 400, width: 50, height: 20)
        XCTAssertEqual(TooltipLogic.origin(anchor: left, size: size, placement: .leading, screen: screen).x, 66)
    }

    // MARK: - Dock and Theme

    func testDockPolicyAndThemeAppearance() {
        XCTAssertEqual(WindowManager.activationPolicy(showInDock: false, windowOpen: false), .accessory)
        XCTAssertEqual(WindowManager.activationPolicy(showInDock: false, windowOpen: true), .regular)
        XCTAssertEqual(WindowManager.activationPolicy(showInDock: true, windowOpen: false), .regular)
        XCTAssertNil(WindowManager.appearance(for: .system))
        XCTAssertEqual(WindowManager.appearance(for: .light)?.name, .aqua)
        XCTAssertEqual(WindowManager.appearance(for: .dark)?.name, .darkAqua)
    }

    // MARK: - UI Settings

    func testUISettingDefaultsAndNoWriteOnInit() {
        let settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertNil(settings.recorder.positionX)
        XCTAssertNil(settings.recorder.positionY)
        XCTAssertFalse(settings.recorder.closeAfterResult)
        XCTAssertFalse(settings.general.menubarClickRecords)
        XCTAssertTrue(settings.recorder.alwaysShowMini)
        XCTAssertEqual(settings.recorder.snapPointID, 0)
        XCTAssertFalse(settings.general.showInDock)
        XCTAssertEqual(settings.general.theme, .system)
        XCTAssertEqual(settings.general.typingWPM, 40)
        XCTAssertEqual(settings.general.onboardingProgress, 0)
        XCTAssertEqual(settings.general.dismissedToasts, [])
        for key in [
            "parrot.recorder.positionX", "parrot.recorder.positionY", "parrot.recorder.closeAfterResult", "parrot.general.menubarClickRecords",
            "parrot.recorder.alwaysShowMini", "parrot.recorder.snapPointID", "parrot.general.showInDock", "parrot.general.theme",
            "parrot.general.typingWPM", "parrot.general.onboardingProgress", "parrot.general.dismissedToasts",
        ] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) written on init")
        }
    }

    func testUISettingsRoundTrip() {
        let first = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        first.recorder.positionX = 120
        first.recorder.positionY = -40
        first.recorder.closeAfterResult = true
        first.general.menubarClickRecords = true
        first.general.showInDock = true
        first.general.theme = .dark
        first.general.typingWPM = 72.5
        first.general.onboardingProgress = 3
        first.general.dismissedToasts = ["home.stats", "modes.create"]

        let second = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertEqual(second.recorder.positionX, 120)
        XCTAssertEqual(second.recorder.positionY, -40)
        XCTAssertTrue(second.recorder.closeAfterResult)
        XCTAssertTrue(second.general.menubarClickRecords)
        XCTAssertTrue(second.general.showInDock)
        XCTAssertEqual(second.general.theme, .dark)
        XCTAssertEqual(second.general.typingWPM, 72.5)
        XCTAssertEqual(second.general.onboardingProgress, 3)
        XCTAssertEqual(second.general.dismissedToasts, ["home.stats", "modes.create"])
        XCTAssertEqual(defaults.string(forKey: "parrot.general.theme"), "dark")

        // Clearing the position removes the keys (back to the default spot).
        second.recorder.positionX = nil
        second.recorder.positionY = nil
        XCTAssertNil(defaults.object(forKey: "parrot.recorder.positionX"))
        let third = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertNil(third.recorder.positionX)
        XCTAssertNil(third.recorder.positionY)
    }

    // MARK: - Quick Start

    func testQuickStartShowsTheSavedBindings() {
        let settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertEqual(
            ShortcutLabels(hotkeys: settings.hotkeys).quickStartRows.map(\.keys),
            ["Right Option", "Esc"]
        )

        settings.hotkeys.hotkeyBinding = HotkeyBinding(keyCode: 0x36, modifiers: [], displayName: "Right Command")
        settings.hotkeys.pushToTalkBinding = HotkeyBinding(keyCode: 0x3F, modifiers: [], displayName: "Fn")
        settings.hotkeys.cancelHotkeyBinding = HotkeyBinding(keyCode: 0x33, modifiers: [.command], displayName: "Cmd+Delete")
        let rows = ShortcutLabels(hotkeys: settings.hotkeys).quickStartRows
        XCTAssertEqual(rows.map(\.keys), ["Right Command", "Fn", "Cmd+Delete"])
        XCTAssertEqual(rows.last?.action, "Cancel recording")
    }

    func testQuickStartSkipsEmptyAndDuplicateBindings() {
        let labels = ShortcutLabels(dictation: nil, pushToTalk: nil, cancel: "Esc")
        XCTAssertEqual(labels.quickStartRows.map(\.keys), ["Esc"])

        let same = ShortcutLabels(dictation: "Fn", pushToTalk: "Fn", cancel: "Esc")
        XCTAssertEqual(same.quickStartRows.map(\.keys), ["Fn", "Esc"])

        XCTAssertNil(ShortcutLabels.label(.empty))
        XCTAssertEqual(ShortcutLabels.label(HotkeyBinding(keyCode: 0, modifiers: [], displayName: "Mouse 4", mouseButton: 3)), "Mouse 4")
    }

    func testRecorderInstallsWithoutAPanel() {
        let context = makeContext(onboarded: true)
        XCTAssertNotNil(context.windows.recorder)
        XCTAssertTrue(RecorderWindowController.current === context.windows.recorder)
        XCTAssertEqual(context.windows.recorder?.model.state.screen, .hidden)
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
