import AVFoundation
import XCTest

@testable import Parrot

/// File transcription through the real controller and pipeline: the
/// fixture written into an AAC .m4a container, decoded, transcribed with
/// cached Parakeet V3, copied to a fake clipboard, flagged from-file.
@MainActor
final class FileTranscriberTests: XCTestCase {

    private var env: ASRTestEnvironment!
    private var pasteboard: FakePasteboard!
    private var temporaryFiles: [URL] = []

    override func setUp() async throws {
        env = ASRTestEnvironment()
        pasteboard = FakePasteboard()
        // Never touch the operator's real clipboard.
        env.services.output.clipboard = ClipboardService(pasteboard: pasteboard, scheduler: ManualScheduler())
    }

    override func tearDown() async throws {
        env.tearDown()
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
    }

    private func temporaryURL(_ ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-file-\(UUID().uuidString).\(ext)")
        temporaryFiles.append(url)
        return url
    }

    /// Writes 16 kHz mono samples into a file of the given format.
    private func write(_ samples: [Float], to url: URL, settings: [String: Any]) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    private func writeM4A(_ samples: [Float]) throws -> URL {
        let url = temporaryURL("m4a")
        try write(samples, to: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ])
        return url
    }

    private func writeWAV(_ samples: [Float]) throws -> URL {
        let url = temporaryURL("wav")
        try write(samples, to: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        return url
    }

    // MARK: - Through the Controller

    func testM4AFileIsTranscribedCopiedAndFlaggedFromFile() async throws {
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        let fixture = try ASRFixture.samples()
        let url = try writeM4A(fixture)

        let controller = DictationController(services: env.services)
        let started = Date()
        let session = try await XCTUnwrapAsync(await FileTranscriber(controller: controller).transcribe(url, mode: Mode(name: "Files")))
        let seconds = Date().timeIntervalSince(started)

        XCTAssertTrue(session.isFromFile)
        XCTAssertEqual(session.sourceFileURL, url)
        XCTAssertEqual(session.outcome, .copiedOnly, "file runs copy, never paste")
        XCTAssertTrue(session.text.lowercased().contains("hello"), "unexpected text: \(session.text)")
        XCTAssertEqual(session.voiceModelID, VoiceModels.parakeetV3.id)
        XCTAssertEqual(ASRFixture.seconds(session.samples), ASRFixture.seconds(fixture), accuracy: 0.2, "decoded back to 16 kHz mono")
        let clipboard = pasteboard.items.first?.entries.first { $0.type == FakePasteboard.plainText }
        XCTAssertEqual(clipboard.map { String(decoding: $0.data, as: UTF8.self) }, session.text)
        XCTAssertEqual(controller.phase, .idle)
        print("[FileTranscriber] m4a \(String(format: "%.2f", ASRFixture.seconds(fixture)))s -> '\(session.text)' in \(String(format: "%.2f", seconds))s")
    }

    func testUnreadableFileFailsWithAReadError() async throws {
        let url = temporaryURL("m4a")
        try Data("this is not audio".utf8).write(to: url)
        let controller = DictationController(services: env.services)
        let session = try await XCTUnwrapAsync(await FileTranscriber(controller: controller).transcribe(url))
        guard case .failed(let message) = session.outcome else {
            return XCTFail("expected a failure, got \(String(describing: session.outcome))")
        }
        XCTAssertTrue(message.hasPrefix("Failed to read audio file"), message)
        XCTAssertTrue(pasteboard.items.isEmpty, "nothing reaches the clipboard")
        XCTAssertEqual(env.toasts, [message])
    }

    func testLongFileIsTranscribedInPieces() async throws {
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        // Keep the silence so the run really is longer than one piece.
        env.settings.transcription.silenceRemoval = false
        let audio = try ASRFixture.samples() + ASRFixture.zeros(seconds: AudioChunker.fileChunkSeconds + 5)
        let url = try writeWAV(audio)

        let started = Date()
        let session = try await XCTUnwrapAsync(await DictationController(services: env.services).transcribe(file: url, mode: nil))
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(session.outcome, .copiedOnly)
        XCTAssertTrue(session.text.lowercased().contains("hello"), "unexpected text: \(session.text)")
        XCTAssertEqual(session.transcriptionAttempts, 2, "two pieces, one recognizer call each")
        XCTAssertEqual(env.services.live.processingProgress, 1)
        print("[FileTranscriber] \(Int(ASRFixture.seconds(audio)))s file in 2 pieces -> '\(session.text)' in \(String(format: "%.2f", seconds))s")
    }

    // MARK: - Pieces

    func testChunkerCutsAtTheQuietestPointNearTheLimit() {
        // 25 s of tone with a silent gap at 9.0 to 9.2 s.
        var samples = [Float](repeating: 0.5, count: 25 * 16_000)
        for i in (9 * 16_000)..<(Int(9.2 * 16_000)) { samples[i] = 0 }
        let ranges = AudioChunker.ranges(for: samples.count, samples: samples, maxSeconds: 10)
        XCTAssertGreaterThanOrEqual(ranges.count, 3)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        for (a, b) in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound, "no gaps or overlaps") }
        for range in ranges { XCTAssertLessThanOrEqual(range.count, 10 * 16_000) }
        let firstCut = Double(ranges[0].upperBound) / 16_000
        XCTAssertEqual(firstCut, 9.1, accuracy: 0.11, "the first cut lands in the silent gap")
        XCTAssertEqual(AudioChunker.ranges(for: 16_000, samples: [Float](repeating: 0, count: 16_000), maxSeconds: 10), [0..<16_000])
    }

    func testChunkLimitPerModelAndFile() {
        XCTAssertNil(TranscribeStage.chunkLimit(for: VoiceModels.parakeetV3, isFromFile: false))
        XCTAssertEqual(TranscribeStage.chunkLimit(for: VoiceModels.parakeetV3, isFromFile: true), AudioChunker.fileChunkSeconds)
        XCTAssertEqual(TranscribeStage.chunkLimit(for: VoiceModels.paraformer, isFromFile: true), 25)
        XCTAssertEqual(TranscribeStage.chunkLimit(for: VoiceModels.deepgramNova3, isFromFile: true), AudioChunker.fileChunkSeconds)
    }
}

/// `XCTUnwrap` for an async-produced optional.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
