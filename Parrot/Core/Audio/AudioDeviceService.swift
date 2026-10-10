import CoreAudio
import Foundation
import Observation

/// Input devices: the system default, a pinned device, fallbacks,
/// exclusions, priority devices, live monitoring and the lid check
/// (au F1 to F8, F13). [AUD]
///
/// `start(services:)` connects the recorder (which asks this service for
/// its device each time capture starts), begins watching Core Audio and the
/// display configuration, and migrates an old numeric device id to a UID.
/// Views read `inputDevices`, `activeDevice` and the selection helpers;
/// they are observable.
@MainActor
@Observable
final class AudioDeviceService {

    /// A device the user hid, connected or not.
    struct HiddenDevice: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    static let defaultQueryTimeout: TimeInterval = 3
    static let lidWarningText =
        "Your MacBook lid is closed. The built-in microphone won't work in clamshell mode. Please select an external microphone."

    /// Connected input devices in system order.
    private(set) var inputDevices: [AudioDevice] = []
    /// UID of the macOS default input.
    private(set) var defaultInputUID: String?
    private(set) var isLidClosed = false

    /// Device queries give up after this long and keep the last known list.
    @ObservationIgnored var queryTimeout: TimeInterval = AudioDeviceService.defaultQueryTimeout

    @ObservationIgnored private let hardware: AudioHardware
    @ObservationIgnored private weak var services: AppServices?
    @ObservationIgnored private var settings: AudioSettings?
    @ObservationIgnored private weak var recorder: AudioRecorder?
    @ObservationIgnored private weak var live: LiveRecordingState?
    @ObservationIgnored private var lidMonitor: LidStateMonitor?
    @ObservationIgnored private var isMonitoring = false

    init(hardware: AudioHardware? = nil) {
        self.hardware = hardware ?? CoreAudioHardware()
    }

    /// Runs once at the end of setup.
    func start(services: AppServices) {
        self.services = services
        attach(settings: services.settings?.audio, recorder: services.audioRecorder, live: services.live)
        startMonitoring()
    }

    /// Connects settings, recorder and live state and reads the devices,
    /// without watching for changes (tests call this directly).
    func attach(settings: AudioSettings?, recorder: AudioRecorder?, live: LiveRecordingState?) {
        self.settings = settings
        self.recorder = recorder
        self.live = live
        refresh()
        migrateLegacySelection()
        recorder?.deviceProvider = { [weak self] purpose in
            self?.device(for: purpose)
        }
        updateLidWarning()
    }

    // MARK: - Reading

    /// The resolver's view of the current devices and settings.
    var resolverInputs: DeviceResolver.Inputs {
        DeviceResolver.Inputs(
            devices: inputDevices,
            defaultUID: defaultInputUID,
            useDefault: followsSystemDefault,
            pinnedUID: settings?.selectedInputDeviceID,
            userExcluded: excludedUIDs,
            selectionCounts: settings?.selectionCounts ?? [:],
            lidClosed: isLidClosed
        )
    }

    var resolution: DeviceResolver.Resolution {
        DeviceResolver.resolve(resolverInputs)
    }

    /// The device the next recording uses.
    var activeDevice: AudioDevice? { resolution.device }

    var systemDefaultDevice: AudioDevice? {
        inputDevices.first { $0.uid == defaultInputUID }
    }

    /// True while following the macOS default input.
    var followsSystemDefault: Bool {
        guard let settings else { return true }
        return settings.useDefaultDevice || settings.selectedInputDeviceID == nil
    }

    /// The pinned device's UID while not following the default.
    var pinnedUID: String? {
        followsSystemDefault ? nil : settings?.selectedInputDeviceID
    }

    /// Connected devices the user can pick (not excluded).
    var selectableDevices: [AudioDevice] {
        inputDevices.filter { !isExcluded($0) }
    }

    /// Devices the user hid, by name.
    var hiddenDevices: [HiddenDevice] {
        (settings?.excludedDevices ?? [:])
            .map { HiddenDevice(uid: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isExcluded(_ device: AudioDevice) -> Bool {
        DeviceResolver.isExcluded(device, userExcluded: excludedUIDs)
    }

    func isPriority(_ device: AudioDevice) -> Bool {
        settings?.priorityDevices[device.uid] != nil
    }

    private var excludedUIDs: Set<String> {
        Set((settings?.excludedDevices ?? [:]).keys)
    }

    // MARK: - Choosing

    /// A manual pick: pins the device, stops following the default and
    /// counts the pick. Excluded devices are refused.
    func select(_ device: AudioDevice) {
        guard let settings else { return }
        guard !isExcluded(device) else {
            diagLog("[Parrot:Audio] Ignoring selection of excluded device: \(device.name)")
            return
        }
        settings.selectedInputDeviceID = device.uid
        settings.useDefaultDevice = false
        settings.selectionCounts[device.uid, default: 0] += 1
        diagLog("[Parrot:Audio] Manual device selection: \(device.name)")
        diagLog("[Parrot:Audio] Tracked device selection: \(device.name) (count: \(settings.selectionCounts[device.uid] ?? 0))")
        selectionChanged()
    }

    func useSystemDefault() {
        settings?.useDefaultDevice = true
        selectionChanged()
    }

    /// Hides a device from pickers and automatic selection, and forgets its
    /// priority and selection history.
    func exclude(_ device: AudioDevice) {
        guard let settings else { return }
        settings.excludedDevices[device.uid] = device.name
        settings.priorityDevices[device.uid] = nil
        settings.selectionCounts[device.uid] = nil
        if pinnedUID == device.uid {
            settings.useDefaultDevice = true
        }
        diagLog("[Parrot:Audio] User excluded audio device: \(device.name)")
        selectionChanged()
    }

    func restore(_ hidden: HiddenDevice) {
        settings?.excludedDevices[hidden.uid] = nil
        diagLog("[Parrot:Audio] User un-excluded audio device: \(hidden.name)")
        selectionChanged()
    }

    /// Marks or unmarks a priority device. Excluded devices cannot be marked.
    func togglePriority(_ device: AudioDevice) {
        guard let settings else { return }
        if settings.priorityDevices[device.uid] != nil {
            settings.priorityDevices[device.uid] = nil
        } else if !isExcluded(device) {
            settings.priorityDevices[device.uid] = Date().timeIntervalSince1970
        }
    }

    // MARK: - Recording

    /// The device for capture, asked by the recorder. Re-reads the hardware
    /// (at most `queryTimeout`), resets an excluded pin, raises the input
    /// volume when a recording starts and the setting asks for it, and
    /// updates the lid warning.
    func device(for purpose: CapturePurpose) -> AudioDevice? {
        refresh()
        let resolution = self.resolution
        if resolution.resetToDefault, let settings {
            diagLog("[Parrot:Audio] Selected device \(settings.selectedInputDeviceID ?? "-") is excluded, resetting to system default")
            settings.useDefaultDevice = true
        }
        log(resolution)
        if purpose == .recording, let device = resolution.device, shouldRaiseInputVolume(for: device) {
            if hardware.setInputVolume(1, device: device.id) {
                diagLog("[Parrot:Audio] Set input volume to 1.0 on \(device.name)")
            } else {
                diagLog("[Parrot:Audio] Could not set input volume on any channel - device may not support input volume control")
            }
        }
        if purpose != .monitoring {
            updateLidWarning(resolution)
        }
        return resolution.device
    }

    /// Auto mic volume applies only while following the system default.
    func shouldRaiseInputVolume(for device: AudioDevice) -> Bool {
        guard let settings, settings.autoMicVolume, followsSystemDefault else { return false }
        return device.uid == defaultInputUID
    }

    // MARK: - Monitoring

    /// Re-reads the devices and default input. Returns false when the query
    /// timed out (the last known list stays).
    @discardableResult
    func refresh() -> Bool {
        guard let snapshot = query() else { return false }
        if snapshot.devices != inputDevices {
            inputDevices = snapshot.devices
        }
        let uid = snapshot.defaultID.flatMap { id in snapshot.devices.first { $0.id == id }?.uid }
        if uid != defaultInputUID {
            defaultInputUID = uid
        }
        return true
    }

    /// Core Audio reported a change.
    func hardwareChanged(_ change: AudioHardwareChange) {
        switch change {
        case .devices:
            let previous = inputDevices
            refresh()
            diagLog("[Parrot:Audio] Device list changed")
            let removed = previous.filter { old in !inputDevices.contains { $0.uid == old.uid } }
            if !removed.isEmpty {
                diagLog("[Parrot:Audio] Removed devices: \(removed.map(\.name))")
            }
            let added = inputDevices.filter { new in !previous.contains { $0.uid == new.uid } }
            if !added.isEmpty {
                autoSelect(from: added, previousActiveUID: activeUID(in: previous))
            }
        case .defaultInput:
            refresh()
            diagLog("[Parrot:Audio] Default input device changed to: \(systemDefaultDevice?.name ?? "none")")
        case .defaultOutput:
            diagLog("[Parrot:Audio] Default output device changed")
            services?.media.defaultOutputDidChange()
            return
        }
        selectionChanged()
    }

    /// The lid opened or closed (after the debounce).
    func lidStateChanged(_ closed: Bool) {
        isLidClosed = closed
        if closed {
            var lidOpen = resolverInputs
            lidOpen.lidClosed = false
            if DeviceResolver.resolve(lidOpen).device?.isBuiltInMic == true {
                if let external = activeDevice, !external.isBuiltInMic {
                    diagLog("[Parrot:Audio] Lid closed, auto-switching from built-in mic to: \(external.name)")
                } else {
                    diagLog("[Parrot:Audio] Lid closed, no external mic found, staying on the built-in mic")
                }
            }
        }
        selectionChanged()
    }

    // MARK: - Private

    private func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        hardware.observeChanges { [weak self] change in
            self?.hardwareChanged(change)
        }
        let monitor = LidStateMonitor()
        monitor.onChange = { [weak self] closed in
            self?.lidStateChanged(closed)
        }
        monitor.start()
        lidMonitor = monitor
        if monitor.isLidClosed != isLidClosed {
            lidStateChanged(monitor.isLidClosed)
        }
    }

    private func activeUID(in devices: [AudioDevice]) -> String? {
        var inputs = resolverInputs
        inputs.devices = devices
        return DeviceResolver.resolve(inputs).device?.uid
    }

    private func autoSelect(from added: [AudioDevice], previousActiveUID: String?) {
        guard let settings,
              let pick = DeviceResolver.autoSelect(
                newlyConnected: added,
                currentUID: previousActiveUID,
                priority: settings.priorityDevices,
                counts: settings.selectionCounts,
                userExcluded: excludedUIDs
              )
        else { return }
        switch pick.reason {
        case .priority:
            diagLog("[Parrot:Audio] Priority device connected, auto-selecting: \(pick.device.name)")
        case .higherCount(let count):
            diagLog("[Parrot:Audio] Previously selected device connected with higher count, auto-selecting: \(pick.device.name) (\(count))")
        }
        settings.selectedInputDeviceID = pick.device.uid
        settings.useDefaultDevice = false
    }

    /// Moves a running recording to the newly resolved device and updates
    /// the lid warning.
    private func selectionChanged() {
        updateLidWarning()
        guard let recorder, recorder.isRecording else { return }
        let target = activeDevice
        guard target?.uid != recorder.currentDevice?.uid else { return }
        diagLog("[Parrot:Audio] Input device changed mid-recording, switching to \(target?.name ?? "default input")")
        recorder.restartCapture(reason: "input device changed")
    }

    private func updateLidWarning(_ resolution: DeviceResolver.Resolution? = nil) {
        let warning = (resolution ?? self.resolution).needsLidWarning ? Self.lidWarningText : nil
        if live?.lidWarning != warning {
            live?.lidWarning = warning
        }
    }

    /// Older builds could store a numeric device id; map it to the UID.
    private func migrateLegacySelection() {
        guard let settings, !inputDevices.isEmpty,
              let migrated = DeviceResolver.migratedPin(stored: settings.selectedInputDeviceID, devices: inputDevices)
        else { return }
        diagLog("[Parrot:Audio] Migrated stored input device id to \(migrated ?? "system default")")
        settings.selectedInputDeviceID = migrated
        if migrated == nil {
            settings.useDefaultDevice = true
        }
    }

    private func log(_ resolution: DeviceResolver.Resolution) {
        let name = resolution.device?.name ?? "-"
        switch resolution.reason {
        case .systemDefault: diagLog("[Parrot:Audio] Using system default input: \(name)")
        case .defaultExcluded: diagLog("[Parrot:Audio] System default input device is excluded, using first available device: \(name)")
        case .lidClosedExternal: diagLog("[Parrot:Audio] Using external device instead of the built-in mic (lid closed): \(name)")
        case .lidClosedBuiltIn: diagLog("[Parrot:Audio] No external device found, falling back to built-in mic")
        case .pinned: diagLog("[Parrot:Audio] Using selected device: \(name)")
        case .fallbackMostSelected(let count): diagLog("[Parrot:Audio] Fallback to previously selected device: \(name) (selection count: \(count))")
        case .fallbackDefault: diagLog("[Parrot:Audio] No previously selected devices available, falling back to system default: \(name)")
        case .lastResort: diagLog("[Parrot:Audio] Using first available device as last resort: \(name)")
        case .noDevices: diagLog("[Parrot:Audio] No audio input devices available")
        }
    }

    // MARK: - Bounded Queries

    private struct Snapshot: Sendable {
        var devices: [AudioDevice]
        var defaultID: AudioDeviceID?
    }

    private final class SnapshotBox: @unchecked Sendable {
        var value: Snapshot?
    }

    /// Reads the hardware on a background queue, waiting at most
    /// `queryTimeout` (au F1: a stuck audio daemon must not hang the app).
    private func query() -> Snapshot? {
        let hardware = self.hardware
        let box = SnapshotBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = Snapshot(devices: hardware.inputDevices(), defaultID: hardware.defaultInputDeviceID())
            done.signal()
        }
        guard done.wait(timeout: .now() + queryTimeout) == .success else {
            diagLog("[Parrot:Audio] Audio device query timed out after \(Int(queryTimeout)) seconds")
            return nil
        }
        return box.value
    }
}
