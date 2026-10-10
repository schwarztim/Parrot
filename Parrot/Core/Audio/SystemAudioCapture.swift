import CoreMedia
import Foundation
import ScreenCaptureKit

/// Records what apps on the main display play (au F24) through
/// ScreenCaptureKit, as 16 kHz mono, and mixes it into the microphone
/// frames. Needs Screen Recording permission. Video is configured as small
/// as possible; only audio is used. [AUD]
final class SystemAudioCapture: NSObject, AudioMixSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    enum CaptureError: LocalizedError {
        case permission
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .permission: return "Permission to record has not been granted"
            case .noDisplay: return "No displays found for audio capture"
            }
        }
    }

    /// Pending system audio is capped at 10 s; older samples are dropped.
    static let maxPendingSamples = 160_000

    private let lock = NSLock()
    private var pending: [Float] = []
    private(set) var droppedSamples = 0
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.parrot.system-audio", qos: .userInitiated)

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permission
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(AudioFrame.sampleRate)
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = false
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 5
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream }
        diagLog("[Parrot:Audio] System audio capture started")
    }

    func stop() async {
        let stream: SCStream? = lock.withLock {
            let current = self.stream
            self.stream = nil
            pending.removeAll()
            return current
        }
        try? await stream?.stopCapture()
    }

    // MARK: - AudioMixSource

    func mix(into samples: inout [Float]) {
        lock.lock()
        let count = min(samples.count, pending.count)
        for index in 0..<count {
            samples[index] = min(max(samples[index] + pending[index], -1), 1)
        }
        pending.removeFirst(count)
        lock.unlock()
    }

    /// Queues system audio for mixing, dropping the oldest past the cap.
    func enqueue(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        pending.append(contentsOf: samples)
        let overflow = pending.count - Self.maxPendingSamples
        if overflow > 0 {
            pending.removeFirst(overflow)
            droppedSamples += overflow
        }
        lock.unlock()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let buffer = list.first, let data = buffer.mData else { return }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            enqueue(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        diagLog("[Parrot:Audio] System audio capture stopped: \(error)")
    }
}
