import XCTest

@testable import Parrot

/// Collects live updates from the stream's callback thread.
private final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [LiveTranscriptUpdate] = []

    func append(_ update: LiveTranscriptUpdate) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    var all: [LiveTranscriptUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

/// A stream that records what it is fed.
private final class RecordingStream: LiveTranscriptionStream, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var received: [Float] = []

    func append(_ samples: [Float]) {
        lock.lock()
        received.append(contentsOf: samples)
        lock.unlock()
    }

    func finish() async throws -> String { "" }
    func cancel() async {}
}

/// Live text on the cached Parakeet V3 model through the recorder sink:
/// the fixture fed in 100 ms frames at real-time pace.
@MainActor
final class StreamingASRTests: XCTestCase {

    func testFixtureInChunksGivesPartialsAndFinalText() async throws {
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        let engine = TranscriptionEngine()
        try await engine.load()

        let log = UpdateLog()
        let stream = try await engine.startLiveStream(options: TranscriptionOptions()) { update in
            log.append(update)
        }
        let sink = LiveFrameSink()
        sink.attach(stream)

        let samples = try ASRFixture.samples()
        let frame = 1_600
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frame)
            sink.consume(AudioFrame(samples: Array(samples[start..<end]), startSample: start))
            start = end
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Give the last window time to decode before ending the stream.
        for _ in 0..<30 where log.all.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let partials = log.all
        let final = try await stream.finish()

        XCTAssertGreaterThanOrEqual(partials.count, 1, "no live update arrived while audio was fed")
        XCTAssertTrue(final.lowercased().contains("hello"), "unexpected final text: \(final)")
        let last = partials.last.map { "\($0.confirmed)|\($0.hypothesis)" } ?? ""
        print("[StreamingASR] partials before finish: \(partials.count), last: \(last), final: \(final)")
    }

    func testSinkHoldsFramesUntilAStreamAttachesThenForwardsInOrder() {
        let sink = LiveFrameSink()
        sink.consume(AudioFrame(samples: [1, 2], startSample: 0))
        sink.consume(AudioFrame(samples: [3], startSample: 2))

        let stream = RecordingStream()
        sink.attach(stream)
        sink.consume(AudioFrame(samples: [4, 5], startSample: 3))
        XCTAssertEqual(stream.received, [1, 2, 3, 4, 5])

        sink.detach()
        sink.consume(AudioFrame(samples: [6], startSample: 5))
        XCTAssertEqual(stream.received, [1, 2, 3, 4, 5], "a detached sink forwards nothing")
    }
}
