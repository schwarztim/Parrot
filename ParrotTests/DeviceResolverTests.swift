import CoreAudio
import XCTest

@testable import Parrot

/// The input device fallback chain, exclusions, auto-select and the old
/// numeric id migration. Pure: no Core Audio.
final class DeviceResolverTests: XCTestCase {

    private let builtIn = AudioDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let usb = AudioDevice(id: 20, uid: "usb-mic", name: "USB Mic")
    private let headset = AudioDevice(id: 30, uid: "headset", name: "Headset")
    private let teams = AudioDevice(id: 40, uid: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio")

    private func inputs(
        devices: [AudioDevice]? = nil,
        defaultUID: String? = "BuiltInMicrophoneDevice",
        useDefault: Bool = true,
        pinned: String? = nil,
        excluded: Set<String> = [],
        counts: [String: Int] = [:],
        lidClosed: Bool = false
    ) -> DeviceResolver.Inputs {
        DeviceResolver.Inputs(
            devices: devices ?? [builtIn, usb, headset],
            defaultUID: defaultUID,
            useDefault: useDefault,
            pinnedUID: pinned,
            userExcluded: excluded,
            selectionCounts: counts,
            lidClosed: lidClosed
        )
    }

    // MARK: - Following the system default

    func testFollowsTheSystemDefault() {
        let result = DeviceResolver.resolve(inputs(defaultUID: "usb-mic"))
        XCTAssertEqual(result.device, usb)
        XCTAssertEqual(result.reason, .systemDefault)
    }

    func testExcludedDefaultUsesFirstAvailableDevice() {
        let result = DeviceResolver.resolve(inputs(excluded: ["BuiltInMicrophoneDevice"]))
        XCTAssertEqual(result.device, usb)
        XCTAssertEqual(result.reason, .defaultExcluded)
    }

    func testLidClosedPrefersAnExternalDevice() {
        let result = DeviceResolver.resolve(inputs(counts: ["headset": 3, "usb-mic": 1], lidClosed: true))
        XCTAssertEqual(result.device, headset, "most selected external device wins")
        XCTAssertEqual(result.reason, .lidClosedExternal)
        XCTAssertFalse(result.needsLidWarning)
    }

    func testLidClosedWithoutExternalKeepsBuiltInAndWarns() {
        let result = DeviceResolver.resolve(inputs(devices: [builtIn, teams], lidClosed: true))
        XCTAssertEqual(result.device, builtIn)
        XCTAssertEqual(result.reason, .lidClosedBuiltIn)
        XCTAssertTrue(result.needsLidWarning)
    }

    func testLidOpenKeepsBuiltIn() {
        let result = DeviceResolver.resolve(inputs())
        XCTAssertEqual(result.device, builtIn)
        XCTAssertFalse(result.needsLidWarning)
    }

    // MARK: - Pinned device

    func testPinnedDeviceIsUsedWhenConnected() {
        let result = DeviceResolver.resolve(inputs(useDefault: false, pinned: "headset"))
        XCTAssertEqual(result.device, headset)
        XCTAssertEqual(result.reason, .pinned)
        XCTAssertFalse(result.resetToDefault)
    }

    func testExcludedPinResetsToSystemDefault() {
        let result = DeviceResolver.resolve(inputs(useDefault: false, pinned: "headset", excluded: ["headset"]))
        XCTAssertEqual(result.device, builtIn)
        XCTAssertTrue(result.resetToDefault)
    }

    func testMissingPinFallsBackToMostSelectedDevice() {
        let result = DeviceResolver.resolve(
            inputs(useDefault: false, pinned: "gone", counts: ["usb-mic": 2, "headset": 5, "gone": 9])
        )
        XCTAssertEqual(result.device, headset)
        XCTAssertEqual(result.reason, .fallbackMostSelected(count: 5))
        XCTAssertFalse(result.resetToDefault, "a missing pin is bypassed, not cleared")
    }

    func testMissingPinWithoutHistoryFallsBackToSystemDefault() {
        let result = DeviceResolver.resolve(inputs(defaultUID: "usb-mic", useDefault: false, pinned: "gone"))
        XCTAssertEqual(result.device, usb)
        XCTAssertEqual(result.reason, .fallbackDefault)
    }

    func testPinnedBuiltInWithLidClosedSwitchesToExternal() {
        let result = DeviceResolver.resolve(
            inputs(useDefault: false, pinned: "BuiltInMicrophoneDevice", lidClosed: true)
        )
        XCTAssertEqual(result.device, usb)
        XCTAssertEqual(result.reason, .lidClosedExternal)
    }

    func testNilPinFollowsDefaultEvenWhenNotUsingDefault() {
        let result = DeviceResolver.resolve(inputs(defaultUID: "headset", useDefault: false, pinned: nil))
        XCTAssertEqual(result.device, headset)
    }

    // MARK: - Last resort and exclusions

    func testUnknownDefaultUsesFirstAvailableDevice() {
        let result = DeviceResolver.resolve(inputs(devices: [teams, usb], defaultUID: nil))
        XCTAssertEqual(result.device, usb, "the loopback driver is never picked while a mic exists")
        XCTAssertEqual(result.reason, .lastResort)
    }

    func testOnlyExcludedDevicesStillRecords() {
        let result = DeviceResolver.resolve(inputs(devices: [teams], defaultUID: nil))
        XCTAssertEqual(result.device, teams)
        XCTAssertEqual(result.reason, .lastResort)
    }

    func testNoDevices() {
        let result = DeviceResolver.resolve(inputs(devices: [], defaultUID: nil))
        XCTAssertNil(result.device)
        XCTAssertEqual(result.reason, .noDevices)
    }

    func testMeetingLoopbackDriversAreExcludedByUIDAndName() {
        XCTAssertTrue(DeviceResolver.isBuiltInExcluded(teams))
        XCTAssertTrue(DeviceResolver.isBuiltInExcluded(AudioDevice(id: 1, uid: "zoom-x", name: "ZoomAudioDevice")))
        XCTAssertFalse(DeviceResolver.isBuiltInExcluded(usb))
        XCTAssertTrue(builtIn.isBuiltInMic)
        XCTAssertFalse(usb.isBuiltInMic)
    }

    // MARK: - Auto-select on connect

    func testNewestPriorityDeviceIsSelectedOnConnect() {
        let pick = DeviceResolver.autoSelect(
            newlyConnected: [usb, headset],
            currentUID: "BuiltInMicrophoneDevice",
            priority: ["usb-mic": 100, "headset": 200],
            counts: ["usb-mic": 50],
            userExcluded: []
        )
        XCTAssertEqual(pick?.device, headset)
        XCTAssertEqual(pick?.reason, .priority)
    }

    func testDeviceWithHigherCountIsSelectedOnConnect() {
        let pick = DeviceResolver.autoSelect(
            newlyConnected: [usb],
            currentUID: "BuiltInMicrophoneDevice",
            priority: [:],
            counts: ["usb-mic": 4, "BuiltInMicrophoneDevice": 2],
            userExcluded: []
        )
        XCTAssertEqual(pick?.device, usb)
        XCTAssertEqual(pick?.reason, .higherCount(4))
    }

    func testLowerCountOrExcludedDeviceIsNotSelected() {
        XCTAssertNil(DeviceResolver.autoSelect(
            newlyConnected: [usb],
            currentUID: "BuiltInMicrophoneDevice",
            priority: [:],
            counts: ["usb-mic": 1, "BuiltInMicrophoneDevice": 3],
            userExcluded: []
        ))
        XCTAssertNil(DeviceResolver.autoSelect(
            newlyConnected: [usb],
            currentUID: nil,
            priority: ["usb-mic": 1],
            counts: ["usb-mic": 9],
            userExcluded: ["usb-mic"]
        ))
    }

    // MARK: - Migration

    func testNumericIdMigratesToUID() {
        let devices = [builtIn, usb]
        XCTAssertEqual(DeviceResolver.migratedPin(stored: "20", devices: devices), .some("usb-mic"))
        XCTAssertEqual(DeviceResolver.migratedPin(stored: "99", devices: devices), .some(nil))
        XCTAssertNil(DeviceResolver.migratedPin(stored: "usb-mic", devices: devices))
        XCTAssertNil(DeviceResolver.migratedPin(stored: nil, devices: devices))
    }
}

/// Fake Core Audio for the device service: no real device is read or changed.
final class FakeAudioHardware: AudioHardware, @unchecked Sendable {
    private let lock = NSLock()
    private var _devices: [AudioDevice]
    private var _defaultID: AudioDeviceID?
    private var _delay: TimeInterval = 0
    private var _volumeCalls: [AudioDeviceID] = []

    init(devices: [AudioDevice], defaultID: AudioDeviceID?) {
        _devices = devices
        _defaultID = defaultID
    }

    var devices: [AudioDevice] {
        get { lock.withLock { _devices } }
        set { lock.withLock { _devices = newValue } }
    }

    var defaultID: AudioDeviceID? {
        get { lock.withLock { _defaultID } }
        set { lock.withLock { _defaultID = newValue } }
    }

    /// Seconds each query takes, to exercise the timeout.
    var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    var volumeCalls: [AudioDeviceID] { lock.withLock { _volumeCalls } }

    func inputDevices() -> [AudioDevice] {
        let wait = delay
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        return devices
    }

    func defaultInputDeviceID() -> AudioDeviceID? { defaultID }

    func setInputVolume(_ volume: Float, device: AudioDeviceID) -> Bool {
        lock.withLock { _volumeCalls.append(device) }
        return true
    }

    func observeChanges(_ handler: @escaping @MainActor (AudioHardwareChange) -> Void) {}
}

/// The device service with fake hardware: choices, exclusions, priority,
/// auto mic volume, the query timeout and the lid warning.
@MainActor
final class AudioDeviceServiceTests: XCTestCase {

    private let builtIn = AudioDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let usb = AudioDevice(id: 20, uid: "usb-mic", name: "USB Mic")

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: AppSettings!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AudioDeviceServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeService(
        devices: [AudioDevice]? = nil,
        defaultID: AudioDeviceID? = 10,
        live: LiveRecordingState? = nil,
        recorder: AudioRecorder? = nil
    ) -> (AudioDeviceService, FakeAudioHardware) {
        let hardware = FakeAudioHardware(devices: devices ?? [builtIn, usb], defaultID: defaultID)
        let service = AudioDeviceService(hardware: hardware)
        service.attach(settings: settings.audio, recorder: recorder, live: live)
        return (service, hardware)
    }

    func testFollowsTheDefaultUntilADeviceIsPicked() {
        let (service, _) = makeService()
        XCTAssertTrue(service.followsSystemDefault)
        XCTAssertEqual(service.activeDevice, builtIn)
        XCTAssertEqual(service.systemDefaultDevice, builtIn)

        service.select(usb)
        XCTAssertEqual(settings.audio.selectedInputDeviceID, "usb-mic")
        XCTAssertFalse(settings.audio.useDefaultDevice)
        XCTAssertEqual(settings.audio.selectionCounts["usb-mic"], 1)
        XCTAssertEqual(service.pinnedUID, "usb-mic")
        XCTAssertEqual(service.activeDevice, usb)

        service.select(usb)
        XCTAssertEqual(settings.audio.selectionCounts["usb-mic"], 2)

        service.useSystemDefault()
        XCTAssertTrue(service.followsSystemDefault)
        XCTAssertEqual(service.activeDevice, builtIn)
    }

    func testExcludeHidesForgetsAndUnpins() {
        let (service, _) = makeService()
        service.select(usb)
        service.togglePriority(usb)
        XCTAssertTrue(service.isPriority(usb))

        service.exclude(usb)
        XCTAssertEqual(settings.audio.excludedDevices, ["usb-mic": "USB Mic"])
        XCTAssertNil(settings.audio.priorityDevices["usb-mic"])
        XCTAssertNil(settings.audio.selectionCounts["usb-mic"])
        XCTAssertTrue(service.followsSystemDefault)
        XCTAssertEqual(service.selectableDevices, [builtIn])
        XCTAssertEqual(service.hiddenDevices.map(\.name), ["USB Mic"])

        service.select(usb)
        service.togglePriority(usb)
        XCTAssertTrue(service.followsSystemDefault, "an excluded device cannot be picked")
        XCTAssertFalse(service.isPriority(usb), "or marked priority")

        service.restore(service.hiddenDevices[0])
        XCTAssertEqual(service.selectableDevices, [builtIn, usb])
        XCTAssertEqual(settings.audio.excludedDevices, [:])
    }

    func testAutoMicVolumeOnlyForTheSystemDefaultAtRecordingStart() {
        let (service, hardware) = makeService()

        _ = service.device(for: .monitoring)
        XCTAssertEqual(hardware.volumeCalls, [], "the settings meter never changes the volume")

        _ = service.device(for: .recording)
        XCTAssertEqual(hardware.volumeCalls, [10])

        service.select(usb)
        _ = service.device(for: .recording)
        XCTAssertEqual(hardware.volumeCalls, [10], "a pinned device keeps its volume")

        service.useSystemDefault()
        settings.audio.autoMicVolume = false
        _ = service.device(for: .recording)
        XCTAssertEqual(hardware.volumeCalls, [10])
    }

    func testSlowQueryTimesOutAndKeepsTheLastKnownDevices() {
        let (service, hardware) = makeService()
        hardware.delay = 1.5
        hardware.devices = [usb]
        service.queryTimeout = 0.2

        let started = Date()
        XCTAssertFalse(service.refresh())
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(service.inputDevices, [builtIn, usb])
    }

    func testNumericDeviceIdMigratesToItsUID() {
        settings.audio.selectedInputDeviceID = "20"
        settings.audio.useDefaultDevice = false
        _ = makeService()
        XCTAssertEqual(settings.audio.selectedInputDeviceID, "usb-mic")
        XCTAssertFalse(settings.audio.useDefaultDevice)
    }

    func testPriorityDeviceIsSelectedWhenItConnects() {
        settings.audio.priorityDevices = ["usb-mic": 1_700_000_000]
        let (service, hardware) = makeService(devices: [builtIn])
        XCTAssertEqual(service.activeDevice, builtIn)

        hardware.devices = [builtIn, usb]
        service.hardwareChanged(.devices)
        XCTAssertEqual(settings.audio.selectedInputDeviceID, "usb-mic")
        XCTAssertFalse(settings.audio.useDefaultDevice)
        XCTAssertEqual(service.activeDevice, usb)
    }

    func testMissingPinnedDeviceFallsBackWithoutClearingThePin() {
        let (service, hardware) = makeService()
        service.select(usb)
        hardware.devices = [builtIn]
        service.hardwareChanged(.devices)
        XCTAssertEqual(service.activeDevice, builtIn)
        XCTAssertEqual(settings.audio.selectedInputDeviceID, "usb-mic")

        hardware.devices = [builtIn, usb]
        service.hardwareChanged(.devices)
        XCTAssertEqual(service.activeDevice, usb, "the pinned device returns when it reconnects")
    }

    func testLidWarningOnlyWhileTheBuiltInMicIsTheOnlyChoice() {
        let live = LiveRecordingState()
        let (service, hardware) = makeService(devices: [builtIn], live: live)
        XCTAssertNil(live.lidWarning)

        service.lidStateChanged(true)
        XCTAssertEqual(live.lidWarning, AudioDeviceService.lidWarningText)
        XCTAssertEqual(service.activeDevice, builtIn)

        hardware.devices = [builtIn, usb]
        service.hardwareChanged(.devices)
        XCTAssertEqual(service.activeDevice, usb, "the external mic replaces the deaf built-in one")
        XCTAssertNil(live.lidWarning)

        service.lidStateChanged(false)
        XCTAssertEqual(service.activeDevice, builtIn)
    }

    func testRecorderAsksTheServiceForItsDevice() throws {
        let recorder = AudioRecorder()
        let (service, _) = makeService(recorder: recorder)
        service.select(usb)
        let provider = try XCTUnwrap(recorder.deviceProvider)
        XCTAssertEqual(provider(.monitoring), usb)
    }
}
