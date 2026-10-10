import AudioToolbox
import CoreAudio
import Foundation

/// A change Core Audio reported on the system object. [AUD]
enum AudioHardwareChange: Sendable {
    case devices
    case defaultInput
    case defaultOutput
}

/// Input-side device queries. Tests pass a fake, so no test touches the
/// real audio hardware. [AUD]
protocol AudioHardware: AnyObject, Sendable {
    /// Connected devices with at least one input channel, in system order.
    func inputDevices() -> [AudioDevice]
    func defaultInputDeviceID() -> AudioDeviceID?
    /// Sets the input volume (0 to 1) on the main element, else on each
    /// channel. False when the device has no settable input volume.
    @discardableResult
    func setInputVolume(_ volume: Float, device: AudioDeviceID) -> Bool
    /// Calls `handler` on the main queue when the device list or a default
    /// device changes.
    func observeChanges(_ handler: @escaping @MainActor (AudioHardwareChange) -> Void)
}

/// Output volume and mute for playback suppression. Tests pass a fake so
/// the real system volume never changes. [AUD]
protocol OutputVolumeControl: AnyObject {
    func defaultOutputDevice() -> AudioDeviceID?
    /// The output volume, 0 to 1.
    func volume(of device: AudioDeviceID) -> Float?
    @discardableResult
    func setVolume(_ volume: Float, of device: AudioDeviceID) -> Bool
    func isMuted(_ device: AudioDeviceID) -> Bool?
    @discardableResult
    func setMuted(_ muted: Bool, of device: AudioDeviceID) -> Bool
    func isBluetooth(_ device: AudioDeviceID) -> Bool
    /// Some process is doing audio I/O on the device right now.
    func isRunningSomewhere(_ device: AudioDeviceID) -> Bool
}

/// The real Core Audio implementation of both protocols. [AUD]
final class CoreAudioHardware: AudioHardware, OutputVolumeControl, @unchecked Sendable {

    private let system = AudioObjectID(kAudioObjectSystemObject)

    init() {}

    // MARK: - Devices

    func inputDevices() -> [AudioDevice] {
        allDeviceIDs().compactMap { id -> AudioDevice? in
            guard inputChannelCount(id) > 0 else { return nil }
            return device(for: id)
        }
    }

    func device(for id: AudioDeviceID) -> AudioDevice {
        AudioDevice(
            id: id,
            uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
            name: string(id, kAudioDevicePropertyDeviceNameCFString) ?? "Unknown Device"
        )
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        let id: AudioDeviceID? = scalar(system, address(kAudioHardwarePropertyDefaultInputDevice), AudioDeviceID(0))
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    func defaultOutputDevice() -> AudioDeviceID? {
        let id: AudioDeviceID? = scalar(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0))
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    func observeChanges(_ handler: @escaping @MainActor (AudioHardwareChange) -> Void) {
        let watched: [(AudioObjectPropertySelector, AudioHardwareChange)] = [
            (kAudioHardwarePropertyDevices, .devices),
            (kAudioHardwarePropertyDefaultInputDevice, .defaultInput),
            (kAudioHardwarePropertyDefaultOutputDevice, .defaultOutput),
        ]
        for (selector, change) in watched {
            var addr = address(selector)
            let status = AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in
                MainActor.assumeIsolated { handler(change) }
            }
            if status != noErr {
                diagLog("[Parrot:Audio] Could not watch \(change): \(status)")
            }
        }
    }

    // MARK: - Input Volume

    @discardableResult
    func setInputVolume(_ volume: Float, device: AudioDeviceID) -> Bool {
        let elements = [kAudioObjectPropertyElementMain] + (0..<inputChannelCount(device)).map { UInt32($0 + 1) }
        var applied = false
        for element in elements {
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, element)
            guard isSettable(device, &addr) else { continue }
            var value = Float32(min(max(volume, 0), 1))
            if AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                applied = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return applied
    }

    // MARK: - Output Volume

    func volume(of device: AudioDeviceID) -> Float? {
        let main: Float32? = scalar(device, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput), Float32(0))
        if let main { return main }
        for element: UInt32 in [1, 2] {
            let value: Float32? = scalar(device, address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element), Float32(0))
            if let value { return value }
        }
        return nil
    }

    @discardableResult
    func setVolume(_ volume: Float, of device: AudioDeviceID) -> Bool {
        var value = Float32(min(max(volume, 0), 1))
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        if isSettable(device, &addr),
           AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
            return true
        }
        var applied = false
        for element: UInt32 in [1, 2] {
            var channel = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
            guard isSettable(device, &channel) else { continue }
            if AudioObjectSetPropertyData(device, &channel, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                applied = true
            }
        }
        return applied
    }

    func isMuted(_ device: AudioDeviceID) -> Bool? {
        let value: UInt32? = scalar(device, address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), UInt32(0))
        return value.map { $0 != 0 }
    }

    @discardableResult
    func setMuted(_ muted: Bool, of device: AudioDeviceID) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        var applied = false
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, element)
            guard isSettable(device, &addr) else { continue }
            if AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                applied = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return applied
    }

    func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let transport: UInt32? = scalar(device, address(kAudioDevicePropertyTransportType), UInt32(0))
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        let running: UInt32? = scalar(device, address(kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32(0))
        return (running ?? 0) != 0
    }

    // MARK: - Helpers

    private func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func isSettable(_ object: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(object, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &addr, &settable) == noErr && settable.boolValue
    }

    /// Reads a plain value property (integers, floats).
    private func scalar<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var addr = addr
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    /// Reads a CFString property; Core Audio returns it retained.
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
