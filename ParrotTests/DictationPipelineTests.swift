import XCTest

@testable import Parrot

// MARK: - Fakes shared by the pipeline and controller tests

/// Records what fake stages and participants did, in order.
final class PipelineEventLog {
    var events: [String] = []
}

struct FakeStageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A stage whose behavior is a closure. Never touches real services.
@MainActor
final class FakeStage: DictationStage {
    let name: String
    let failurePolicy: StageFailurePolicy
    let runsAfterFinish: Bool
    private let log: PipelineEventLog
    private let action: @MainActor (DictationSession) async throws -> StageResult

    init(services: AppServices) {
        name = "FakeStage"
        failurePolicy = .skip
        runsAfterFinish = false
        log = PipelineEventLog()
        action = { _ in .continue }
    }

    init(
        _ name: String,
        policy: StageFailurePolicy = .skip,
        runsAfterFinish: Bool = false,
        log: PipelineEventLog,
        action: @escaping @MainActor (DictationSession) async throws -> StageResult = { _ in .continue }
    ) {
        self.name = name
        self.failurePolicy = policy
        self.runsAfterFinish = runsAfterFinish
        self.log = log
        self.action = action
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        log.events.append(name)
        return try await action(session)
    }
}

/// A participant that logs every hook, optionally holding `willStart` open
/// until released, and optionally running a closure in `willStop`.
@MainActor
final class FakeParticipant: RecordingParticipant {
    let label: String
    private let log: PipelineEventLog
    var holdWillStart = false
    private(set) var isHoldingWillStart = false
    private var release: CheckedContinuation<Void, Never>?
    var onWillStop: (@MainActor (DictationSession) -> Void)?

    init(services: AppServices) {
        label = "P"
        log = PipelineEventLog()
    }

    init(_ label: String, log: PipelineEventLog) {
        self.label = label
        self.log = log
    }

    func willStart(_ session: DictationSession) async {
        log.events.append("\(label).willStart")
        guard holdWillStart else { return }
        await withCheckedContinuation { continuation in
            release = continuation
            isHoldingWillStart = true
        }
    }

    func releaseWillStart() {
        isHoldingWillStart = false
        release?.resume()
        release = nil
    }

    func didStart(_ session: DictationSession) { log.events.append("\(label).didStart") }

    func willStop(_ session: DictationSession) {
        log.events.append("\(label).willStop")
        onWillStop?(session)
    }

    func didFinish(_ session: DictationSession) { log.events.append("\(label).didFinish") }
    func didCancel(_ session: DictationSession) { log.events.append("\(label).didCancel") }
}

/// Holds a stage open until the test releases it.
@MainActor
final class StageGate {
    private(set) var isHolding = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { c in
            continuation = c
            isHolding = true
        }
    }

    func open() {
        isHolding = false
        continuation?.resume()
        continuation = nil
    }
}

/// Lets queued main-actor work run until `condition` holds (bounded).
@MainActor
func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("condition never became true", file: file, line: line)
}

// MARK: - Pipeline Tests

private enum NoteKey: SessionKey {
    static var defaultValue: String { "none" }
}

private enum CountKey: SessionKey {
    static var defaultValue: Int { 0 }
}

/// Stage order, failure policies, early finish, cancel and timings, using
/// fake stages only. No audio, network, settings or Keychain.
@MainActor
final class DictationPipelineTests: XCTestCase {

    // XCTest makes a fresh instance per test, so these start empty each time.
    private let log = PipelineEventLog()
    private var warnings: [String] = []

    private func makePipeline(_ stages: [FakeStage], participants: [FakeParticipant] = []) -> DictationPipeline {
        DictationPipeline(stages: stages, participants: participants) { [unowned self] message in
            self.warnings.append(message)
        }
    }

    private func makeSession() -> DictationSession {
        DictationSession(trigger: .pushToTalk)
    }

    func testStagesRunInOrderAndShareTheWorkingText() async {
        let pipeline = makePipeline([
            FakeStage("A", log: log) { $0.text = "a"; return .continue },
            FakeStage("B", log: log) { $0.text += "b"; return .continue },
            FakeStage("C", log: log) { $0.text += "c"; return .continue },
        ])
        let session = makeSession()

        await pipeline.run(session)

        XCTAssertEqual(log.events, ["A", "B", "C"])
        XCTAssertEqual(session.text, "abc")
        XCTAssertNil(session.outcome)
    }

    func testSkipPolicyKeepsCurrentTextAndContinues() async {
        let participant = FakeParticipant("P", log: log)
        let pipeline = makePipeline([
            FakeStage("A", log: log) { $0.text = "hello"; return .continue },
            FakeStage("B", policy: .skip, log: log) { session in
                session.text = "garbled"
                throw FakeStageError(message: "refiner down")
            },
            FakeStage("C", log: log),
        ], participants: [participant])
        let session = makeSession()

        await pipeline.run(session)

        XCTAssertEqual(log.events, ["A", "B", "C", "P.didFinish"])
        XCTAssertEqual(session.text, "hello")
        XCTAssertEqual(session.warnings, ["B: refiner down"])
        XCTAssertEqual(warnings, ["refiner down"])
        XCTAssertNil(session.outcome)
    }

    func testAbortPolicySetsFailedOutcomeAndSkipsLaterStages() async {
        let participant = FakeParticipant("P", log: log)
        let pipeline = makePipeline([
            FakeStage("Transcribe", policy: .abort, log: log) { _ in
                throw FakeStageError(message: "engine not ready")
            },
            FakeStage("Deliver", log: log),
            FakeStage("Persist", runsAfterFinish: true, log: log),
        ], participants: [participant])
        let session = makeSession()

        await pipeline.run(session)

        XCTAssertEqual(session.outcome, .failed("engine not ready"))
        XCTAssertEqual(log.events, ["Transcribe", "P.didFinish", "Persist"])
        XCTAssertTrue(warnings.isEmpty)
    }

    func testRunsAfterFinishStagesRunAfterAnEarlyFinish() async {
        let participant = FakeParticipant("P", log: log)
        let pipeline = makePipeline([
            FakeStage("Cleanup", log: log) { _ in .finish(.empty) },
            FakeStage("Refine", log: log),
            FakeStage("Deliver", log: log),
            FakeStage("Persist", runsAfterFinish: true, log: log),
        ], participants: [participant])
        let session = makeSession()

        await pipeline.run(session)

        XCTAssertEqual(session.outcome, .empty)
        // didFinish goes out at the finish, before the after-finish stage.
        XCTAssertEqual(log.events, ["Cleanup", "P.didFinish", "Persist"])
    }

    func testLaterFinishDoesNotReplaceTheFirstOutcome() async {
        let pipeline = makePipeline([
            FakeStage("A", log: log) { _ in .finish(.routedToAgent) },
            FakeStage("Persist", runsAfterFinish: true, log: log) { _ in .finish(.pasted) },
        ])
        let session = makeSession()

        await pipeline.run(session)

        XCTAssertEqual(session.outcome, .routedToAgent)
    }

    func testNothingRunsAfterCancelIncludingAfterFinishStages() async {
        let participant = FakeParticipant("P", log: log)
        let pipeline = makePipeline([
            FakeStage("A", log: log) { $0.isCancelled = true; return .continue },
            FakeStage("B", log: log),
            FakeStage("Persist", runsAfterFinish: true, log: log),
        ], participants: [participant])
        let session = makeSession()

        await pipeline.run(session)

        XCTAssertEqual(log.events, ["A", "P.didCancel"])
        XCTAssertNil(session.outcome)
    }

    func testCancelAfterEarlyFinishStopsAfterFinishStages() async {
        let participant = FakeParticipant("P", log: log)
        let pipeline = makePipeline([
            FakeStage("A", log: log) { session in
                session.isCancelled = true
                return .finish(.empty)
            },
            FakeStage("Persist", runsAfterFinish: true, log: log),
        ], participants: [participant])
        let session = makeSession()

        await pipeline.run(session)

        XCTAssertEqual(log.events, ["A", "P.didCancel"])
    }

    func testTimingsRecordedForEveryStageThatRan() async {
        let pipeline = makePipeline([
            FakeStage("Slow", log: log) { _ in
                try await Task.sleep(nanoseconds: 20_000_000)
                return .continue
            },
            FakeStage("Throws", policy: .skip, log: log) { _ in throw FakeStageError(message: "x") },
            FakeStage("Finish", log: log) { _ in .finish(.pasted) },
            FakeStage("Skipped", log: log),
            FakeStage("Persist", runsAfterFinish: true, log: log),
        ])
        let session = makeSession()

        await pipeline.run(session)

        XCTAssertEqual(Set(session.timings.keys), ["Slow", "Throws", "Finish", "Persist"])
        XCTAssertGreaterThanOrEqual(session.timings["Slow"] ?? 0, 0.015)
        XCTAssertTrue(session.timings.values.allSatisfy { $0 >= 0 })
    }

    func testParticipantHooksFanOutInOrder() async {
        let pipeline = makePipeline([], participants: [
            FakeParticipant("P1", log: log),
            FakeParticipant("P2", log: log),
        ])
        let session = makeSession()

        await pipeline.willStart(session)
        pipeline.didStart(session)
        pipeline.willStop(session)
        await pipeline.run(session)

        XCTAssertEqual(log.events, [
            "P1.willStart", "P2.willStart",
            "P1.didStart", "P2.didStart",
            "P1.willStop", "P2.willStop",
            "P1.didFinish", "P2.didFinish",
        ])
    }

    func testSessionKeyReturnsDefaultThenStoredValue() {
        let session = makeSession()

        XCTAssertEqual(session[NoteKey.self], "none")
        session[NoteKey.self] = "kept"
        session[CountKey.self] += 2

        XCTAssertEqual(session[NoteKey.self], "kept")
        XCTAssertEqual(session[CountKey.self], 2)
        XCTAssertEqual(makeSession()[NoteKey.self], "none")
    }

    func testPipelineOrderMatchesThePlan() {
        XCTAssertEqual(PipelineOrder.participants.map { String(describing: $0) }, [
            "RecorderUIParticipant", "ContextCaptureParticipant", "PlaybackParticipant",
            "SoundCueParticipant", "LevelMeterParticipant", "RecordingWriterParticipant",
            "LiveTranscriptionParticipant", "OutputParticipant", "AgentParticipant",
        ])
        XCTAssertEqual(PipelineOrder.stages.map { String(describing: $0) }, [
            "PreprocessAudioStage", "TranscribeStage", "TranscriptCleanupStage",
            "ReplacementsStage", "RefineStage", "PostRefineReplacementsStage",
            "AgentRouteStage", "FormatOutputStage", "DeliverStage",
            "PostActionStage", "PersistStage",
        ])
    }
}
