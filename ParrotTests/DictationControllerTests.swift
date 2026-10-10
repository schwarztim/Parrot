import XCTest

@testable import Parrot

/// A recorder that never touches audio hardware.
final class FakeRecorder: AudioCapturing {
    var startCount = 0
    var stopCount = 0
    var startError: Error?
    var samplesToReturn: [Float] = Array(repeating: 0.1, count: 16_000)
    var didReachCapacity = false

    func startRecording() throws {
        if let startError { throw startError }
        startCount += 1
    }

    func stopRecording() -> [Float] {
        stopCount += 1
        return samplesToReturn
    }
}

/// Records the delegate calls the controller makes.
@MainActor
final class FakeControllerDelegate: DictationControllerDelegate {
    var events: [String] = []
    var endedSessions: [DictationSession] = []

    func dictationWillOpenMic(_ session: DictationSession) { events.append("willOpenMic") }
    func dictationDidStartRecording(_ session: DictationSession) { events.append("didStartRecording") }
    func dictationDidFailToStart(_ session: DictationSession, error: Error) { events.append("didFailToStart") }
    func dictationDidStopRecording(_ session: DictationSession) { events.append("didStopRecording") }
    func dictationDidBeginProcessing(_ session: DictationSession) { events.append("didBeginProcessing") }
    func dictationDidEnd(_ session: DictationSession) {
        events.append("didEnd")
        endedSessions.append(session)
    }
}

/// Phase guards, pending stop, cancel from each phase and the minimum
/// duration floor, with a fake recorder, fake stages and a fake participant.
@MainActor
final class DictationControllerTests: XCTestCase {

    // XCTest makes a fresh instance per test, so every fake starts clean.
    private let log = PipelineEventLog()
    private let recorder = FakeRecorder()
    private var toasts: [String] = []
    private lazy var participant = FakeParticipant("P", log: log)
    private lazy var delegate = FakeControllerDelegate()
    private lazy var services: AppServices = {
        // A temp path that is never written: the controller never saves vocabulary.
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-controllertests-\(UUID().uuidString)")
            .appendingPathComponent("vocabulary.json")
        let services = AppServices(vocabulary: VocabularyManager(storageURL: storage))
        services.showTransientError = { [unowned self] message in self.toasts.append(message) }
        return services
    }()

    /// A controller whose single stage marks the session pasted, optionally
    /// held open by `gate`.
    private func makeController(gate: StageGate? = nil) -> DictationController {
        let deliver = FakeStage("Deliver", log: log) { session in
            if let gate { await gate.hold() }
            session.outcome = .pasted
            return .continue
        }
        let pipeline = DictationPipeline(stages: [deliver], participants: [participant])
        let recorder = self.recorder
        let controller = DictationController(services: services, pipeline: pipeline) { recorder }
        controller.delegate = delegate
        return controller
    }

    // MARK: - Start Guards

    func testStartOpensTheMicAndStartWhileRecordingIsIgnored() async {
        let controller = makeController()

        await controller.start(trigger: .pushToTalk)?.value
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(services.live.phase, .recording)
        XCTAssertEqual(services.live.trigger, .pushToTalk)

        XCTAssertNil(controller.start(trigger: .url))
        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(log.events, ["P.willStart", "P.didStart"])
        XCTAssertEqual(delegate.events, ["willOpenMic", "didStartRecording"])
    }

    func testStartWithoutARecorderIsIgnored() {
        let controller = DictationController(
            services: services,
            pipeline: DictationPipeline(stages: [], participants: [participant]),
            recorder: { nil }
        )

        XCTAssertNil(controller.start(trigger: .toggle))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(log.events.isEmpty)
    }

    func testStartWhileProcessingIsIgnored() async {
        let gate = StageGate()
        let controller = makeController(gate: gate)
        await controller.start(trigger: .toggle)?.value
        let processing = controller.stop(trigger: .toggle)
        await waitUntil { gate.isHolding }
        XCTAssertEqual(controller.phase, .processing)

        XCTAssertNil(controller.start(trigger: .toggle))
        XCTAssertNil(controller.toggle(trigger: .toggle))

        gate.open()
        await processing?.value
        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testStartAndCancelWhileStoppingAreIgnored() async {
        let controller = makeController()
        var phaseSeen: DictationPhase?
        var startIgnored = false
        participant.onWillStop = { [unowned controller] _ in
            phaseSeen = controller.phase
            startIgnored = controller.start(trigger: .toggle) == nil
            controller.cancel()
        }
        await controller.start(trigger: .toggle)?.value

        await controller.stop(trigger: .toggle)?.value

        XCTAssertEqual(phaseSeen, .stopping)
        XCTAssertTrue(startIgnored)
        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(delegate.endedSessions.first?.outcome, .pasted)
        XCTAssertEqual(delegate.endedSessions.first?.isCancelled, false)
    }

    // MARK: - Pending Stop

    func testStopWhileStartingBecomesPendingStopAndStopsOnceStarted() async {
        let controller = makeController()
        participant.holdWillStart = true

        let starting = controller.start(trigger: .pushToTalk)
        await waitUntil { participant.isHoldingWillStart }
        XCTAssertEqual(controller.phase, .starting)

        XCTAssertNil(controller.stop(trigger: .pushToTalk))
        XCTAssertTrue(controller.pendingStop)
        XCTAssertEqual(recorder.startCount, 0)

        participant.releaseWillStart()
        await starting?.value

        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertFalse(controller.pendingStop)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(log.events, ["P.willStart", "P.didStart", "P.willStop", "Deliver", "P.didFinish"])
        XCTAssertEqual(delegate.endedSessions.first?.outcome, .pasted)
    }

    // MARK: - Cancel From Each Phase

    func testCancelWhileIdleDoesNothing() {
        let controller = makeController()

        controller.cancel()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertTrue(delegate.events.isEmpty)
    }

    func testCancelWhileStartingNeverOpensTheMic() async {
        let controller = makeController()
        participant.holdWillStart = true

        let starting = controller.start(trigger: .toggle)
        await waitUntil { participant.isHoldingWillStart }
        controller.cancel()
        participant.releaseWillStart()
        await starting?.value

        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(log.events, ["P.willStart", "P.didCancel"])
        XCTAssertTrue(delegate.events.isEmpty)
    }

    func testCancelWhileRecordingDiscardsWithoutRunningStages() async {
        let controller = makeController()
        await controller.start(trigger: .toggle)?.value

        controller.cancel()

        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.session)
        XCTAssertEqual(log.events, ["P.willStart", "P.didStart", "P.didCancel"])
        XCTAssertEqual(delegate.events.last, "didEnd")
        XCTAssertEqual(delegate.endedSessions.first?.isCancelled, true)
    }

    func testCancelWhileProcessingIsIgnored() async {
        let gate = StageGate()
        let controller = makeController(gate: gate)
        await controller.start(trigger: .toggle)?.value
        let processing = controller.stop(trigger: .toggle)
        await waitUntil { gate.isHolding }

        controller.cancel()
        gate.open()
        await processing?.value

        XCTAssertEqual(log.events.last, "P.didFinish")
        XCTAssertEqual(delegate.endedSessions.first?.outcome, .pasted)
        XCTAssertEqual(delegate.endedSessions.first?.isCancelled, false)
    }

    // MARK: - Minimum Duration Floor

    func testRecordingShorterThanTheFloorIsDiscarded() async {
        let controller = makeController()
        recorder.samplesToReturn = Array(repeating: 0.1, count: 4_799) // just under 0.3 s
        await controller.start(trigger: .pushToTalk)?.value

        XCTAssertNil(controller.stop(trigger: .pushToTalk))

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(log.events.contains("Deliver"))
        XCTAssertEqual(log.events.suffix(2), ["P.willStop", "P.didFinish"])
        XCTAssertEqual(delegate.events, ["willOpenMic", "didStartRecording", "didStopRecording", "didEnd"])
        XCTAssertEqual(delegate.endedSessions.first?.outcome, .discarded)
    }

    func testEmptyRecordingIsDiscarded() async {
        let controller = makeController()
        recorder.samplesToReturn = []
        await controller.start(trigger: .pushToTalk)?.value

        XCTAssertNil(controller.stop(trigger: .pushToTalk))

        XCTAssertFalse(log.events.contains("Deliver"))
        XCTAssertEqual(delegate.endedSessions.first?.outcome, .discarded)
    }

    func testRecordingAtTheFloorRunsTheStages() async {
        let controller = makeController()
        recorder.samplesToReturn = Array(repeating: 0.1, count: 4_800) // exactly 0.3 s
        await controller.start(trigger: .pushToTalk)?.value

        let processing = controller.stop(trigger: .pushToTalk)
        XCTAssertEqual(controller.phase, .processing)
        await processing?.value

        XCTAssertTrue(log.events.contains("Deliver"))
        XCTAssertEqual(delegate.events, [
            "willOpenMic", "didStartRecording", "didStopRecording", "didBeginProcessing", "didEnd",
        ])
        XCTAssertEqual(delegate.endedSessions.first?.samples.count, 4_800)
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - Other Paths

    func testStartFailureReportsAndReturnsToIdle() async {
        let controller = makeController()
        recorder.startError = FakeStageError(message: "no input device")

        await controller.start(trigger: .toggle)?.value

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(log.events, ["P.willStart", "P.didFinish"])
        XCTAssertEqual(delegate.events, ["willOpenMic", "didFailToStart"])
    }

    func testToggleStartsWhenIdleAndStopsWhenRecording() async {
        let controller = makeController()

        await controller.toggle(trigger: .url)?.value
        XCTAssertEqual(controller.phase, .recording)

        await controller.toggle(trigger: .url)?.value
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertTrue(log.events.contains("Deliver"))
    }

    func testCapacityWarningIsShownWhenTheRecordingHitTheCap() async {
        let controller = makeController()
        recorder.didReachCapacity = true
        await controller.start(trigger: .toggle)?.value

        await controller.stop(trigger: .toggle)?.value

        XCTAssertEqual(toasts, ["Recording reached the 2 minute limit; the end may be cut off."])
    }

    func testModeOverrideIsFrozenOnTheSession() async {
        let controller = makeController()
        let mode = Mode(name: "Email")

        await controller.start(trigger: .modeShortcut, modeOverride: mode)?.value
        await controller.stop(trigger: .modeShortcut)?.value

        XCTAssertEqual(delegate.endedSessions.first?.mode?.name, "Email")
        XCTAssertEqual(delegate.endedSessions.first?.trigger, .modeShortcut)
    }
}
