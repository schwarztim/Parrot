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
