import XCTest

@testable import Parrot

/// A fresh install's defaults for the settings the parity specs pin down,
/// each checked against its spec row. Empty defaults suite, in-memory
/// secrets.
@MainActor
final class SettingsDefaultsTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "parrot.tests.defaults.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshInstallMatchesTheSpecs() {
        let settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())

        // ui 3.6 row 3, `enableSilenceRemoval`: true.
        XCTAssertTrue(settings.transcription.silenceRemoval, "silence removal")
        // oh F1 / ui 3.5 row 7, `autoPasteEnabled`: true.
        XCTAssertTrue(settings.output.autoPaste, "auto-paste")
        // oh F2, `clipboardBehaviour`: bypass ("Keep what I have copied").
        XCTAssertEqual(settings.output.clipboardBehaviour, .keep, "clipboard behaviour")
        // oh F2, `restoreClipboardTimeDelay`: 1.0 s.
        XCTAssertEqual(settings.output.restoreDelay, 1.0, "restore delay")
        // ui 3.6 row 4 / au F14, `defaultPlaybackBehavior`: pause.
        XCTAssertEqual(settings.audio.playbackBehavior, .pause, "playback when recording")
        // ui 3.6 row 5, sound effects: Simple, enabled.
        XCTAssertEqual(settings.audio.soundTheme, .simple, "sound theme")
        XCTAssertTrue(settings.audio.soundEffectsEnabled, "sound effects on")
        // hd F10 / ui 3.4 row 5, `recordingRetentionDuration`: Forever (0).
        XCTAssertEqual(settings.history.historyRetentionDays, 0, "retention keeps recordings forever")
        XCTAssertEqual(RetentionOption(rawValue: settings.history.historyRetentionDays), .forever)
        // ui 3.4 row 6: Classic recorder.
        XCTAssertEqual(settings.recorder.recordingWindowStyle, .classic, "recorder style")
        // ui 2.1 / 3.4 row 7, `alwaysShowMiniRecorder`: true.
        XCTAssertTrue(settings.recorder.alwaysShowMini, "always show mini")
        // ui 3.5 row 1, `showApplicationInDock`: true.
        XCTAssertTrue(settings.general.showInDock, "show in Dock")
    }

    func testExistingInstallStaysMenuBarOnly() {
        // An install that already finished onboarding was menu-bar-only;
        // upgrading must not add a Dock icon on its own.
        defaults.set(true, forKey: "parrot.hasCompletedOnboarding")
        let settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())

        XCTAssertFalse(settings.general.showInDock)
    }
}
