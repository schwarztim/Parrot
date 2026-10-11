import XCTest

@testable import Parrot

/// The "No Audio Detected" check and the 20 Hz level stream. Fed synthetic
/// zeros and the speech fixture; never opens the microphone.
@MainActor
final class SilentMicTests: XCTestCase {

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [LevelMeter.Event] = []

        func append(_ new: [LevelMeter.Event]) {
            lock.lock()
            events += new
            lock.unlock()
        }

        var all: [LevelMeter.Event] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        var silentChanges: [Bool] {
            all.compactMap { if case .silentMic(let on) = $0 { return on } else { return nil } }
        }

        var levelCount: Int {
            all.reduce(0) { count, event in
                if case .levels(let levels) = event { return count + levels.count }
                return count
            }
        }
    }

    private func feed(_ samples: [Float], to meter: LevelMeter, from start: inout Int, chunk: Int = 1_600) {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            meter.consume(AudioFrame(samples: Array(samples[offset..<end]), startSample: start + offset))
            offset = end
        }
        start += samples.count
    }

    private let zeros = [Float](repeating: 0, count: 49_600) // 3.1 s

    func testThreeSilentSecondsWarnThenSpeechClears() throws {
        let log = EventLog()
        let meter = LevelMeter { log.append($0) }
        var position = 0

        feed(zeros, to: meter, from: &position)
        XCTAssertEqual(log.silentChanges, [true])

        feed(try AudioFixture.samples(), to: meter, from: &position)
        XCTAssertEqual(log.silentChanges, [true, false])
    }

    func testNoWarningBeforeThreeSeconds() {
        let log = EventLog()
        let meter = LevelMeter { log.append($0) }
        var position = 0
        feed(Array(zeros.prefix(46_400)), to: meter, from: &position) // 2.9 s
        XCTAssertEqual(log.silentChanges, [])
    }

    func testSpeechInTheFirstSecondsNeverWarns() throws {
        let log = EventLog()
        let meter = LevelMeter { log.append($0) }
        var position = 0
        feed(try AudioFixture.samples(), to: meter, from: &position)
        feed(zeros, to: meter, from: &position)
        XCTAssertEqual(log.silentChanges, [])
    }

    func testThresholdIsMinus55dBFS() {
        var quiet = SilentMicDetector()
        XCTAssertNil(quiet.process(peak: 0.0017, endTime: 1))
        XCTAssertEqual(quiet.process(peak: 0.0017, endTime: 3), .warn)
        XCTAssertNil(quiet.process(peak: 0.0017, endTime: 4))
        XCTAssertEqual(quiet.process(peak: 0.0018, endTime: 5), .clear)

        var audible = SilentMicDetector()
        XCTAssertNil(audible.process(peak: 0.0018, endTime: 3))
        XCTAssertFalse(audible.isWarning)
    }

    func testLevelsArriveTwentyPerSecondOfAudio() {
        let log = EventLog()
        let meter = LevelMeter { log.append($0) }
        var position = 0
        feed(zeros, to: meter, from: &position)
        XCTAssertEqual(log.levelCount, 62) // 3.1 s at 20 Hz
    }

    // MARK: - Participant

    /// Waits past the 50 ms level spacing so every queued update has landed.
    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
    }

    func testBufferLevelsAreSpreadFiftyMillisecondsApart() {
        let batches = LevelMeterParticipant.spread([.levels([0.1, 0.2]), .silentMic(true)])
        XCTAssertEqual(batches.map(\.0), [0, 0.05, 0])
        XCTAssertEqual(batches.map(\.1), [[.levels([0.1])], [.levels([0.2])], [.silentMic(true)]])
    }

    func testParticipantPublishesWarningLevelsAndClears() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("SilentMicTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storage) }
        let services = AppServices(vocabulary: VocabularyManager(storageURL: storage))
        let recorder = AudioRecorder()
        services.audioRecorder = recorder
        let participant = LevelMeterParticipant(services: services)
        let session = DictationSession(trigger: .menu)
        session.deviceName = "Desk Mic"
        services.live.silentMicDevice = "stale"

        await participant.willStart(session)
        XCTAssertNil(services.live.silentMicDevice, "a new recording clears the old warning")
        participant.didStart(session)
        XCTAssertEqual(session.deviceName, "Desk Mic")

        AudioFixture.feed(zeros, to: recorder)
        await drainMainQueue()
        XCTAssertEqual(services.live.silentMicDevice, "Desk Mic")
        XCTAssertFalse(services.live.levels.isEmpty)
        XCTAssertLessThanOrEqual(services.live.levels.count, LevelMeterParticipant.historySize)

        AudioFixture.feed(try AudioFixture.samples(), to: recorder)
        await drainMainQueue()
        XCTAssertNil(services.live.silentMicDevice)
        XCTAssertGreaterThan(services.live.levels.max() ?? 0, 0.5, "speech fills the bars")

        participant.willStop(session)
        XCTAssertEqual(services.live.levels, [])
        AudioFixture.feed(zeros, to: recorder)
        await drainMainQueue()
        XCTAssertEqual(services.live.levels, [], "no levels after the mic closed")
    }

    func testWarningSurvivesStopForTheNoAudioBanner() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("SilentMicTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storage) }
        let services = AppServices(vocabulary: VocabularyManager(storageURL: storage))
        let recorder = AudioRecorder()
        services.audioRecorder = recorder
        let participant = LevelMeterParticipant(services: services)
        let session = DictationSession(trigger: .menu)
        session.deviceName = "Desk Mic"

        await participant.willStart(session)
        AudioFixture.feed(zeros, to: recorder)
        await drainMainQueue()
        participant.willStop(session)
        session.outcome = .empty
        participant.didFinish(session)
        XCTAssertEqual(services.live.silentMicDevice, "Desk Mic")
    }
}
