import XCTest

@testable import Parrot

/// Global default plus per-mode override for playback while recording.
final class PlaybackResolutionTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PlaybackResolutionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
    }

    func testModeValueWinsOverGlobal() {
        XCTAssertEqual(PlaybackResolution.resolve(mode: .mute, global: .pause), .mute)
        XCTAssertEqual(PlaybackResolution.resolve(mode: .keepPlaying, global: .duck), .keepPlaying)
    }

    func testMissingModeValueUsesGlobal() {
        XCTAssertEqual(PlaybackResolution.resolve(mode: nil, global: .duck), .duck)
    }

    func testFreshInstallDefaultsToPause() {
        let settings = makeSettings()
        XCTAssertEqual(settings.audio.playbackBehavior, .pause)
        XCTAssertEqual(settings.audio.soundTheme, .simple)
        XCTAssertTrue(settings.audio.useDefaultDevice)
        XCTAssertEqual(settings.audio.excludedDevices, [:])
    }

    func testUnknownStoredGlobalReadsAsPause() {
        defaults.set("loud", forKey: "parrot.audio.playbackBehavior")
        XCTAssertEqual(makeSettings().audio.playbackBehavior, .pause)
    }

    func testGlobalAndDictionariesPersist() {
        let settings = makeSettings()
        settings.audio.playbackBehavior = .mute
        settings.audio.excludedDevices = ["uid-1": "Loopback"]
        settings.audio.selectionCounts = ["uid-2": 3]
        settings.audio.priorityDevices = ["uid-3": 1_700_000_000]
        settings.audio.soundTheme = .classic

        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.audio.playbackBehavior, .mute)
        XCTAssertEqual(reloaded.audio.excludedDevices, ["uid-1": "Loopback"])
        XCTAssertEqual(reloaded.audio.selectionCounts, ["uid-2": 3])
        XCTAssertEqual(reloaded.audio.priorityDevices, ["uid-3": 1_700_000_000])
        XCTAssertEqual(reloaded.audio.soundTheme, .classic)
    }

    func testStoredDeviceFromOlderBuildStaysPinned() {
        defaults.set("usb-mic", forKey: "parrot.selectedInputDeviceID")
        let settings = makeSettings()
        XCTAssertFalse(settings.audio.useDefaultDevice)
        XCTAssertNil(defaults.object(forKey: "parrot.audio.useDefaultDevice"), "init never writes")
    }

    func testTargetVolumes() {
        XCTAssertNil(PlaybackResolution.targetVolume(for: .keepPlaying, currentVolume: 0.8))
        XCTAssertEqual(PlaybackResolution.targetVolume(for: .duck, currentVolume: 0.8), 0.15)
        XCTAssertEqual(PlaybackResolution.targetVolume(for: .duck, currentVolume: 0.1), 0.1, "never raised")
        XCTAssertEqual(PlaybackResolution.targetVolume(for: .pause, currentVolume: 0.6), 0.15)
        XCTAssertEqual(PlaybackResolution.targetVolume(for: .mute, currentVolume: 0.6), 0)
    }

    func testDefaultLabelShowsTheGlobalValue() {
        XCTAssertEqual(AudioModeSection.defaultLabel(global: .pause), "Pause (Default)")
        XCTAssertEqual(AudioModeSection.defaultLabel(global: .duck), "Lower (Default)")
    }
}
