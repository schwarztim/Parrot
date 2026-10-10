import AVFoundation
import XCTest

@testable import Parrot

/// Collects frames from the audio thread.
final class CollectingSink: AudioFrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [AudioFrame] = []

    var frames: [AudioFrame] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func consume(_ frame: AudioFrame) {
        lock.lock()
        collected.append(frame)
        lock.unlock()
    }
}

/// Frame sink fan-out, fed synthetic buffers directly. The engine is never
/// started, so no microphone is opened.
final class AudioRecorderSinkTests: XCTestCase {

    private let format16k = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private func monoBuffer(sampleRate: Double, frames: Int, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buffer.floatChannelData![0][i] = value
        }
        return buffer
    }

    func testSinkReceivesEachBufferWithRunningOffsets() {
        let recorder = AudioRecorder()
        let sink = CollectingSink()
        recorder.addSink(sink)
        recorder.addSink(sink) // a second add is ignored

        recorder.processCapturedBuffer(
            monoBuffer(sampleRate: 16_000, frames: 1_600, value: 0.25), converter: nil, desiredFormat: format16k
        )
        recorder.processCapturedBuffer(
            monoBuffer(sampleRate: 16_000, frames: 800, value: 0.5), converter: nil, desiredFormat: format16k
        )

        XCTAssertEqual(sink.frames.map(\.samples.count), [1_600, 800])
        XCTAssertEqual(sink.frames.map(\.startSample), [0, 1_600])
        XCTAssertEqual(sink.frames.first?.samples.first, 0.25)
        XCTAssertEqual(sink.frames.last?.samples.last, 0.5)
    }

    func testRemovedSinkReceivesNothing() {
        let recorder = AudioRecorder()
        let kept = CollectingSink()
        let removed = CollectingSink()
        recorder.addSink(kept)
        recorder.addSink(removed)
        recorder.removeSink(removed)

        recorder.processCapturedBuffer(
            monoBuffer(sampleRate: 16_000, frames: 160, value: 0.1), converter: nil, desiredFormat: format16k
        )

        XCTAssertEqual(kept.frames.count, 1)
        XCTAssertTrue(removed.frames.isEmpty)
    }

    func testHardwareRateBuffersArriveAs16kMono() {
        let recorder = AudioRecorder()
        let sink = CollectingSink()
        recorder.addSink(sink)
        let hardware = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        )!
        let converter = AVAudioConverter(from: hardware, to: format16k)!

        recorder.processCapturedBuffer(
            monoBuffer(sampleRate: 48_000, frames: 4_800, value: 0.2), converter: converter, desiredFormat: format16k
        )

        // 100 ms at 48 kHz is about 1,600 samples at 16 kHz (resampler edges vary).
        let count = sink.frames.first?.samples.count ?? 0
        XCTAssertEqual(Double(count), 1_600, accuracy: 200)
    }
}
