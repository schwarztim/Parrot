import AVFoundation
import XCTest

@testable import Parrot

/// The `hello-parrot.wav` fixture (16 kHz mono speech, about 3 s) as floats.
enum AudioFixture {
    static func samples(file: StaticString = #filePath, line: UInt = #line) throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "hello-parrot", withExtension: "wav", subdirectory: "Resources"),
            "hello-parrot.wav fixture missing from test bundle", file: file, line: line
        )
        return try decode(url)
    }

    static func decode(_ url: URL) throws -> [Float] {
        let audio = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(max(audio.length, 1)))
        )
        try audio.read(into: buffer)
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: count))
    }

    /// A 16 kHz mono buffer holding `samples`, for `processCapturedBuffer`.
    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            buffer.floatChannelData![0][index] = sample
        }
        return buffer
    }

    static let format16k = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    /// Feeds `samples` to the recorder in 100 ms buffers, as the tap would.
    static func feed(_ samples: [Float], to recorder: AudioRecorder, chunk: Int = 1_600) {
        var start = 0
        while start < samples.count {
            let end = min(start + chunk, samples.count)
            recorder.processCapturedBuffer(buffer(Array(samples[start..<end])), converter: nil, desiredFormat: format16k)
            start = end
        }
    }
}

/// Crash-safe WAV streaming and the per-recording folder. Uses a temporary
/// root; never opens the microphone.
@MainActor
final class WavStreamWriterTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WavStreamWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - Writer

    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    private func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        data.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }

    private func ascii(_ data: Data, _ offset: Int) -> String {
        String(decoding: data.subdata(in: offset..<offset + 4), as: UTF8.self)
    }

    private func assertValidHeader(_ url: URL, samples expected: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + expected * 2, "file size", file: file, line: line)
        XCTAssertEqual(ascii(data, 0), "RIFF", file: file, line: line)
        XCTAssertEqual(Int(uint32(data, 4)), data.count - 8, "RIFF size", file: file, line: line)
        XCTAssertEqual(ascii(data, 8), "WAVE", file: file, line: line)
        XCTAssertEqual(ascii(data, 12), "fmt ", file: file, line: line)
        XCTAssertEqual(uint32(data, 16), 16, file: file, line: line)
        XCTAssertEqual(uint16(data, 20), 1, "PCM", file: file, line: line)
        XCTAssertEqual(uint16(data, 22), 1, "mono", file: file, line: line)
        XCTAssertEqual(uint32(data, 24), 16_000, "sample rate", file: file, line: line)
        XCTAssertEqual(uint32(data, 28), 32_000, "byte rate", file: file, line: line)
        XCTAssertEqual(uint16(data, 32), 2, "block align", file: file, line: line)
        XCTAssertEqual(uint16(data, 34), 16, "bits", file: file, line: line)
        XCTAssertEqual(ascii(data, 36), "data", file: file, line: line)
        XCTAssertEqual(Int(uint32(data, 40)), expected * 2, "data size", file: file, line: line)
    }

    func testHeaderIsValidAfterEveryFlushAndTheFileDecodes() throws {
        let fixture = try AudioFixture.samples()
        let url = root.appendingPathComponent("output.wav")
        let writer = try WavStreamWriter(url: url)
        try assertValidHeader(url, samples: 0)

        var fed = 0
        while fed < fixture.count {
            let end = min(fed + 7_000, fixture.count)
            writer.consume(AudioFrame(samples: Array(fixture[fed..<end]), startSample: fed))
            fed = end
            try writer.flush()
            try assertValidHeader(url, samples: fed)
            // A crash right now leaves a playable file.
            XCTAssertEqual(try AudioFixture.decode(url).count, fed)
        }
        try writer.finish()
        try writer.finish() // a second finish does nothing

        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(audio.fileFormat.channelCount, 1)
        let decoded = try AudioFixture.decode(url)
        XCTAssertEqual(decoded.count, fixture.count)
        let maxError = zip(decoded, fixture).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(maxError, 0.0002, "16-bit round trip")
    }

    func testOutOfRangeSamplesAreClamped() {
        let data = WavStreamWriter.pcm16([2, -2, .nan, 0.5])
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map(\.littleEndian)
        XCTAssertEqual(values, [32_767, -32_767, 0, 16_384])
    }

    // MARK: - Participant

    private func makeServices() -> AppServices {
        let services = AppServices(vocabulary: VocabularyManager(storageURL: root.appendingPathComponent("vocabulary.json")))
        services.paths = AppPaths(root: root)
        services.audioRecorder = AudioRecorder()
        services.showTransientError = { message in XCTFail("unexpected toast: \(message)") }
        return services
    }

    func testRecordingLandsInItsUnixSecondsFolder() async throws {
        let services = makeServices()
        let participant = RecordingWriterParticipant(services: services)
        let session = DictationSession(trigger: .menu)
        let fixture = try AudioFixture.samples()

        await participant.willStart(session)
        let folder = try XCTUnwrap(session.recordingFolder)
        XCTAssertEqual(folder.lastPathComponent, String(Int(session.startedAt.timeIntervalSince1970)))
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL, services.paths.recordings.standardizedFileURL)

        AudioFixture.feed(fixture, to: services.audioRecorder!)
        participant.willStop(session)
        participant.didFinish(session) // after willStop, a no-op

        let decoded = try AudioFixture.decode(services.paths.recordingAudio(in: folder))
        XCTAssertEqual(decoded.count, fixture.count)
        XCTAssertEqual(session.recordingFolder, folder)
    }

    func testCancelDiscardsTheFolder() async throws {
        let services = makeServices()
        let participant = RecordingWriterParticipant(services: services)
        let session = DictationSession(trigger: .menu)

        await participant.willStart(session)
        let folder = try XCTUnwrap(session.recordingFolder)
        AudioFixture.feed(try AudioFixture.samples(), to: services.audioRecorder!)
        participant.didCancel(session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(session.recordingFolder)
    }

    func testFailedStartLeavesNoFolder() async throws {
        let services = makeServices()
        let participant = RecordingWriterParticipant(services: services)
        let session = DictationSession(trigger: .menu)

        await participant.willStart(session)
        let folder = try XCTUnwrap(session.recordingFolder)
        session.outcome = .failed("mic busy")
        participant.didFinish(session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(session.recordingFolder)
    }

    func testBackToBackRecordingsNeverShareAFolder() async throws {
        let services = makeServices()
        let participant = RecordingWriterParticipant(services: services)
        let fixture = Array(try AudioFixture.samples().prefix(8_000))

        let first = DictationSession(trigger: .menu)
        await participant.willStart(first)
        AudioFixture.feed(fixture, to: services.audioRecorder!)
        participant.willStop(first)

        let second = DictationSession(trigger: .menu)
        await participant.willStart(second)
        AudioFixture.feed(fixture, to: services.audioRecorder!)
        participant.willStop(second)

        let firstFolder = try XCTUnwrap(first.recordingFolder)
        let secondFolder = try XCTUnwrap(second.recordingFolder)
        XCTAssertNotEqual(firstFolder, secondFolder)
        XCTAssertEqual(try AudioFixture.decode(services.paths.recordingAudio(in: firstFolder)).count, 8_000)
        XCTAssertEqual(try AudioFixture.decode(services.paths.recordingAudio(in: secondFolder)).count, 8_000)
    }

    func testOfflineSessionsWriteNothing() async throws {
        let services = makeServices()
        let participant = RecordingWriterParticipant(services: services)
        let session = DictationSession(trigger: .menu, source: .reprocess(7))

        await participant.willStart(session)
        XCTAssertNil(session.recordingFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: services.paths.recordings.path))
    }
}
