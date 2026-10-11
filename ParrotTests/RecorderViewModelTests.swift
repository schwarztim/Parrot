import CoreGraphics
import XCTest

@testable import Parrot

/// The recorder's pure logic: every view state the reducer produces, the
/// discard guard, what happens when a session ends, level bars, timer text,
/// digit hints and placement. Also RecorderUIParticipant's writes into
/// LiveRecordingState with a fake presenter. The window itself needs a GUI
/// session and is not covered here.
@MainActor
final class RecorderViewModelTests: XCTestCase {

    private func reduce(_ configure: (inout RecorderInput) -> Void) -> RecorderViewState {
        var input = RecorderInput()
        configure(&input)
        return RecorderViewModel.reduce(input)
    }

    // MARK: - Screens by Phase

    func testIdleWithNothingIsHidden() {
        let state = reduce { _ in }
        XCTAssertEqual(state.screen, .hidden)
        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(state.primaryButton, .none)
        XCTAssertFalse(state.showsCancel)
    }

    func testStartingShowsReadyWithStopAndCancel() {
        let state = reduce { $0.phase = .starting }
        XCTAssertEqual(state.screen, .ready)
        XCTAssertEqual(state.primaryButton, .stop)
        XCTAssertTrue(state.showsCancel)
        XCTAssertFalse(state.showsTimer)
    }

    func testRecordingShowsWaveWithTimerStopAndCancel() {
        let start = Date(timeIntervalSince1970: 1_000)
        let state = reduce {
            $0.phase = .recording
            $0.startedAt = start
            $0.levels = [0.2, 0.4]
        }
        XCTAssertEqual(state.screen, .wave)
        XCTAssertEqual(state.primaryButton, .stop)
        XCTAssertTrue(state.showsCancel)
        XCTAssertTrue(state.showsTimer)
        XCTAssertEqual(state.startedAt, start)
        XCTAssertEqual(state.levels, [0.2, 0.4])
    }

    func testRecordingWithLiveTextShowsLiveText() {
        let state = reduce {
            $0.phase = .recording
            $0.confirmedText = "Hello "
            $0.hypothesisText = "wor"
        }
        XCTAssertEqual(state.screen, .liveText)
        XCTAssertEqual(state.confirmedText, "Hello ")
        XCTAssertEqual(state.hypothesisText, "wor")
        XCTAssertEqual(state.primaryButton, .stop)
    }

    func testWhitespaceOnlyLiveTextStaysOnTheWave() {
        let state = reduce {
            $0.phase = .recording
            $0.hypothesisText = "  "
        }
        XCTAssertEqual(state.screen, .wave)
    }

    func testStoppingAndProcessingShowProgressWithoutButtons() {
        for phase in [DictationPhase.stopping, .processing] {
            let state = reduce {
                $0.phase = phase
                $0.processingProgress = 0.5
            }
            XCTAssertEqual(state.screen, .processing, "\(phase)")
            XCTAssertEqual(state.progress, 0.5)
            XCTAssertEqual(state.primaryButton, .none)
            XCTAssertFalse(state.showsCancel, "cancel is ignored while processing")
            XCTAssertFalse(state.isFinalizing)
        }
    }

    func testProcessingWithLiveTextIsFinalizing() {
        let state = reduce {
            $0.phase = .processing
            $0.confirmedText = "Hello world"
        }
        XCTAssertEqual(state.screen, .processing)
        XCTAssertTrue(state.isFinalizing)
    }

    func testResultWrittenDuringProcessingShowsTheResult() {
        let state = reduce {
            $0.phase = .processing
            $0.resultText = "Hello world."
            $0.processingProgress = 0.9
        }
        XCTAssertEqual(state.screen, .result)
        XCTAssertEqual(state.resultText, "Hello world.")
        XCTAssertNil(state.progress)
    }

    func testIdleResultLingersWithClose() {
        let state = reduce { $0.resultText = "Hello world." }
        XCTAssertEqual(state.screen, .result)
        XCTAssertEqual(state.primaryButton, .close)
        XCTAssertFalse(state.showsCancel)
        XCTAssertFalse(state.showsTimer)
    }

    func testEmptyResultTextIsIgnored() {
        XCTAssertEqual(reduce { $0.resultText = "" }.screen, .hidden)
        XCTAssertNil(reduce { $0.resultText = "" }.resultText)
    }

    func testIdleErrorWinsOverResult() {
        let state = reduce {
            $0.resultText = "Old text"
            $0.errorText = "Transcription failed"
        }
        XCTAssertEqual(state.screen, .error)
        XCTAssertEqual(state.banner, .error("Transcription failed"))
        XCTAssertEqual(state.primaryButton, .close)
    }

    func testErrorDuringProcessingShowsTheError() {
        let state = reduce {
            $0.phase = .processing
            $0.errorText = "Model not ready"
        }
        XCTAssertEqual(state.screen, .error)
    }

    // MARK: - Banners

    func testNoAudioBannerAndItsSilentMicVariant() {
        let plain = reduce { $0.errorText = RecorderViewModel.noAudioMessage }
        XCTAssertEqual(plain.banner, .noAudio)
        XCTAssertEqual(plain.banner?.title, "No Audio Detected")
        XCTAssertEqual(plain.banner?.offersSwitchMic, false)

        let silent = reduce {
            $0.errorText = RecorderViewModel.noAudioMessage
            $0.silentMicDevice = "USB Mic"
        }
        XCTAssertEqual(silent.banner, .silentMic(device: "USB Mic"))
        XCTAssertEqual(silent.banner?.offersSwitchMic, true)
    }

    func testSilentMicBannerShowsWhileRecording() {
        let state = reduce {
            $0.phase = .recording
            $0.silentMicDevice = "USB Mic"
        }
        XCTAssertEqual(state.screen, .wave)
        XCTAssertEqual(state.banner, .silentMic(device: "USB Mic"))
    }

    func testLidWarningShowsOnlyDuringASession() {
        XCTAssertEqual(
            reduce { $0.phase = .recording; $0.lidWarning = "Lid is Closed" }.banner,
            .lidClosed("Lid is Closed")
        )
        XCTAssertNil(reduce { $0.lidWarning = "Lid is Closed" }.banner)
    }

    // MARK: - Discard Guard

    func testCancelGuardShowsOnlyWhileRecording() {
        let guarded = reduce {
            $0.phase = .recording
            $0.cancelGuardShown = true
        }
        XCTAssertEqual(guarded.screen, .cancelGuard)
        XCTAssertEqual(guarded.primaryButton, .none, "the guard has its own Discard and Resume")
        XCTAssertFalse(guarded.showsCancel)
        XCTAssertTrue(guarded.showsTimer, "the recording keeps running behind the guard")

        // A stop that lands while the guard is open wins.
        for phase in [DictationPhase.idle, .starting, .stopping, .processing] {
            let state = reduce {
                $0.phase = phase
                $0.cancelGuardShown = true
            }
            XCTAssertNotEqual(state.screen, .cancelGuard, "\(phase)")
        }
    }

    func testDiscardGuardFlowResumeAndDiscard() {
        var input = RecorderInput()
        input.phase = .starting
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .ready)

        input.phase = .recording
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .wave)

        // Cancel asks first.
        input.cancelGuardShown = true
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .cancelGuard)

        // Resume goes back to the recording.
        input.cancelGuardShown = false
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .wave)

        // Asked again, then discarded: the controller returns to idle and the
        // participant clears the guard.
        input.cancelGuardShown = true
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .cancelGuard)
        input.phase = .idle
        input.cancelGuardShown = false
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .hidden)
    }

    func testFullDictationFlowToLingeringResultAndClose() {
        var input = RecorderInput()
        input.phase = .starting
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .ready)
        input.phase = .recording
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .wave)
        input.phase = .stopping
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .processing)
        input.phase = .processing
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .processing)
        // The paste could not be confirmed: the result stays after idle.
        input.resultText = "Hello."
        input.phase = .idle
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .result)
        // Close clears it.
        input.resultText = nil
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .hidden)
    }

    // MARK: - Mode Switcher and HUD

    func testModeSwitcherWinsInEveryPhaseAndStyle() {
        for phase in [DictationPhase.idle, .starting, .recording, .stopping, .processing] {
            for style in RecordingWindowStyle.allCases {
                let state = reduce {
                    $0.phase = phase
                    $0.style = style
                    $0.modeSwitcherShown = true
                    $0.cancelGuardShown = true
                    $0.resultText = "text"
                }
                XCTAssertEqual(state.screen, .modeSwitch, "\(phase) \(style)")
                XCTAssertEqual(state.primaryButton, .close)
            }
        }
    }

    func testModeChangedShowsAloneWhenIdleAndOverTheRecording() {
        let idle = reduce { $0.modeChangedName = "Email" }
        XCTAssertEqual(idle.screen, .modeChanged)
        XCTAssertEqual(idle.hudModeName, "Email")

        let recording = reduce {
            $0.phase = .recording
            $0.modeChangedName = "Email"
        }
        XCTAssertEqual(recording.screen, .wave)
        XCTAssertEqual(recording.hudModeName, "Email")

        let switching = reduce {
            $0.modeSwitcherShown = true
            $0.modeChangedName = "Email"
        }
        XCTAssertNil(switching.hudModeName, "no note on top of the open list")
    }

    // MARK: - Style None

    func testStyleNoneHidesEverythingButTheSwitcherAndModeNote() {
        let screens: [(RecorderScreen, (inout RecorderInput) -> Void)] = [
            (.hidden, { $0.phase = .starting }),
            (.hidden, { $0.phase = .recording }),
            (.hidden, { $0.phase = .recording; $0.cancelGuardShown = true }),
            (.hidden, { $0.phase = .processing }),
            (.hidden, { $0.resultText = "text" }),
            (.hidden, { $0.errorText = "error" }),
            (.modeSwitch, { $0.modeSwitcherShown = true }),
            (.modeChanged, { $0.modeChangedName = "Email" }),
        ]
        for (expected, configure) in screens {
            let state = reduce {
                $0.style = .none
                configure(&$0)
            }
            XCTAssertEqual(state.screen, expected)
        }
    }

    func testMiniStyleKeepsTheSameScreens() {
        let state = reduce {
            $0.style = .mini
            $0.phase = .recording
        }
        XCTAssertEqual(state.screen, .wave)
        XCTAssertEqual(state.style, .mini)
    }

    // MARK: - Labels and Chips

    func testModeNameFallsBackToSelectedModeThenDefault() {
        XCTAssertEqual(reduce { $0.modeName = "Code"; $0.selectedModeName = "General" }.modeName, "Code")
        XCTAssertEqual(reduce { $0.selectedModeName = "General" }.modeName, "General")
        XCTAssertEqual(reduce { _ in }.modeName, "Default")
    }

    func testDestinationLabelPassesThrough() {
        XCTAssertEqual(reduce { $0.phase = .recording; $0.destinationLabel = "Mail (Subject)" }.destinationLabel, "Mail (Subject)")
    }

    func testChipsShowDuringTheSessionOnly() {
        let recording = reduce {
            $0.phase = .recording
            $0.selectionChip = "selected words"
            $0.clipboardChip = "copied words"
        }
        XCTAssertEqual(recording.chips.map(\.kind), [.selection, .clipboard])
        XCTAssertEqual(recording.chips.first?.title, "Selected text included in context")
        XCTAssertEqual(recording.chips.last?.title, "Clipboard text found")
        XCTAssertEqual(recording.chips.first?.detail, "selected words")

        let result = reduce {
            $0.resultText = "done"
            $0.selectionChip = "selected words"
        }
        XCTAssertTrue(result.chips.isEmpty)
    }

    // MARK: - Session End

    func testEndingForEachOutcome() {
        func ending(_ outcome: DictationOutcome?, text: String = "Hello.", closeAfterResult: Bool = false) -> RecorderEnding {
            RecorderViewModel.ending(outcome: outcome, isCancelled: false, text: text, closeAfterResult: closeAfterResult)
        }
        XCTAssertEqual(ending(.pasted), .close, "a confirmed paste closes")
        XCTAssertEqual(ending(.copiedOnly), .showResult("Hello."), "an unconfirmed paste lingers")
        XCTAssertEqual(ending(.copiedOnly, closeAfterResult: true), .close, "Always close")
        XCTAssertEqual(ending(.copiedOnly, text: "  "), .close)
        XCTAssertEqual(ending(.empty), .showError(RecorderViewModel.noAudioMessage))
        XCTAssertEqual(ending(.empty, closeAfterResult: true), .showError(RecorderViewModel.noAudioMessage))
        XCTAssertEqual(ending(.failed("Model not ready")), .showError("Model not ready"))
        XCTAssertEqual(ending(.failed("")), .showError("Dictation failed"))
        XCTAssertEqual(ending(.discarded), .close)
        XCTAssertEqual(ending(.routedToAgent), .close)
        XCTAssertEqual(ending(nil), .close)
    }

    func testCancelledSessionAlwaysCloses() {
        for outcome: DictationOutcome? in [.pasted, .copiedOnly, .empty, .failed("x"), nil] {
            XCTAssertEqual(
                RecorderViewModel.ending(outcome: outcome, isCancelled: true, text: "Hello.", closeAfterResult: false),
                .close
            )
        }
    }

    // MARK: - Level Bars

    func testIdleBarsMoveGentlyWithTime() {
        let first = RecorderViewModel.barHeights(levels: [], count: 30, time: 0)
        let later = RecorderViewModel.barHeights(levels: [], count: 30, time: 0.5)
        XCTAssertEqual(first.count, 30)
        XCTAssertNotEqual(first, later)
        for height in first + later {
            XCTAssertGreaterThanOrEqual(height, 0.04)
            XCTAssertLessThanOrEqual(height, 0.2)
        }
    }

    func testLevelBarsUseTheNewestLevelsPaddedOnTheLeft() {
        let heights = RecorderViewModel.barHeights(levels: [0.5, 0.9], count: 4, time: 0)
        XCTAssertEqual(heights.count, 4)
        XCTAssertEqual(heights[0], 0.06)
        XCTAssertEqual(heights[1], 0.06)
        XCTAssertEqual(heights[2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(heights[3], 0.9, accuracy: 1e-6)

        let newest = RecorderViewModel.barHeights(levels: [0.1, 0.2, 0.3, 0.4, 0.5], count: 3, time: 0)
        XCTAssertEqual(newest.count, 3)
        XCTAssertEqual(newest[0], Double(Float(0.3)), accuracy: 1e-6)
        XCTAssertEqual(newest[2], Double(Float(0.5)), accuracy: 1e-6)
    }

    func testLevelBarsClampAndFloor() {
        let heights = RecorderViewModel.barHeights(levels: [-1, 0, 2, .nan, .infinity], count: 5, time: 0)
        XCTAssertEqual(heights, [0.06, 0.06, 1, 0.06, 0.06])
        XCTAssertEqual(RecorderViewModel.barHeights(levels: [0.5], count: 0, time: 0), [])
    }

    // MARK: - Timer and Digits

    func testElapsedText() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(RecorderViewModel.elapsedText(since: nil, now: start), "0:00")
        XCTAssertEqual(RecorderViewModel.elapsedText(since: start, now: start.addingTimeInterval(5.9)), "0:05")
        XCTAssertEqual(RecorderViewModel.elapsedText(since: start, now: start.addingTimeInterval(65)), "1:05")
        XCTAssertEqual(RecorderViewModel.elapsedText(since: start, now: start.addingTimeInterval(-3)), "0:00")
    }

    func testDigitHints() {
        XCTAssertEqual(RecorderViewModel.digitHint(forIndex: 0), "1")
        XCTAssertEqual(RecorderViewModel.digitHint(forIndex: 8), "9")
        XCTAssertEqual(RecorderViewModel.digitHint(forIndex: 9), "0")
        XCTAssertNil(RecorderViewModel.digitHint(forIndex: 10))
        XCTAssertNil(RecorderViewModel.digitHint(forIndex: -1))
    }

    // MARK: - Placement

    private let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let rightScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
    private let size = CGSize(width: 453, height: 200)

    func testDefaultOriginIsBottomCenterOfTheFallbackScreen() {
        let origin = RecorderViewModel.origin(saved: nil, size: size, screens: [mainScreen], fallback: mainScreen)
        XCTAssertEqual(origin, CGPoint(x: 720 - 226.5, y: 60))
    }

    func testSavedOriginOnAnyScreenIsKept() {
        let saved = CGPoint(x: 2000, y: 500)
        let origin = RecorderViewModel.origin(saved: saved, size: size, screens: [mainScreen, rightScreen], fallback: mainScreen)
        XCTAssertEqual(origin, saved)
    }

    func testSavedOriginOnAMissingScreenFallsBack() {
        let saved = CGPoint(x: 2000, y: 500)
        let origin = RecorderViewModel.origin(saved: saved, size: size, screens: [mainScreen], fallback: mainScreen)
        XCTAssertEqual(origin, CGPoint(x: 720 - 226.5, y: 60))
    }

    func testSavedOriginHangingOffAnEdgeIsPulledInside() {
        // Mostly on screen (center inside), but the top runs past the edge.
        let saved = CGPoint(x: 100, y: 760)
        let origin = RecorderViewModel.origin(saved: saved, size: size, screens: [mainScreen], fallback: mainScreen)
        XCTAssertEqual(origin, CGPoint(x: 100, y: 875 - 200))
    }

    // MARK: - Participant

    private var suiteName: String?

    override func tearDown() {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private func makeServices(closeAfterResult: Bool = false) -> AppServices {
        let name = "RecorderViewModelTests-\(UUID().uuidString)"
        suiteName = name
        let settings = AppSettings(store: SettingsStore(defaults: UserDefaults(suiteName: name)!), secrets: InMemorySecretStore())
        settings.recorder.closeAfterResult = closeAfterResult
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-recordertests-\(UUID().uuidString)")
            .appendingPathComponent("vocabulary.json")
        let services = AppServices(vocabulary: VocabularyManager(storageURL: storage))
        services.settings = settings
        return services
    }

    private func finished(_ outcome: DictationOutcome?, text: String = "Hello.") -> DictationSession {
        let session = DictationSession(trigger: .pushToTalk)
        session.outcome = outcome
        session.text = text
        return session
    }

    func testWillStartClearsTheLastSessionAndShowsTheRecorder() async {
        let services = makeServices()
        let presenter = FakeRecorderPresenter()
        services.recorderUI = presenter
        let live = services.live
        live.resultText = "old"
        live.errorText = "old error"
        live.cancelGuardShown = true
        live.modeSwitcherShown = true
        live.confirmedText = "old"
        live.hypothesisText = "old"
        live.levels = [0.5]
        live.processingProgress = 1

        await RecorderUIParticipant(services: services).willStart(DictationSession(trigger: .pushToTalk))

        XCTAssertNil(live.resultText)
        XCTAssertNil(live.errorText)
        XCTAssertFalse(live.cancelGuardShown)
        XCTAssertFalse(live.modeSwitcherShown)
        XCTAssertEqual(live.confirmedText, "")
        XCTAssertEqual(live.hypothesisText, "")
        XCTAssertEqual(live.levels, [])
        XCTAssertNil(live.processingProgress)
        XCTAssertEqual(presenter.events, ["show"])
    }

    func testWillStopClosesTheGuard() {
        let services = makeServices()
        services.live.cancelGuardShown = true
        RecorderUIParticipant(services: services).willStop(DictationSession(trigger: .pushToTalk))
        XCTAssertFalse(services.live.cancelGuardShown)
    }

    func testConfirmedPasteHidesAndClearsAResultWrittenByDelivery() {
        let services = makeServices()
        let presenter = FakeRecorderPresenter()
        services.recorderUI = presenter
        services.live.resultText = "Hello."
        services.live.cancelGuardShown = true
        services.live.modeSwitcherShown = true

        RecorderUIParticipant(services: services).didFinish(finished(.pasted))

        XCTAssertNil(services.live.resultText)
        XCTAssertNil(services.live.errorText)
        XCTAssertFalse(services.live.cancelGuardShown)
        XCTAssertFalse(services.live.modeSwitcherShown)
        XCTAssertEqual(presenter.events, ["hide"])
    }

    func testUnconfirmedPasteLeavesTheResultOnScreen() {
        let services = makeServices()
        let presenter = FakeRecorderPresenter()
        services.recorderUI = presenter

        RecorderUIParticipant(services: services).didFinish(finished(.copiedOnly, text: "Hello there."))

        XCTAssertEqual(services.live.resultText, "Hello there.")
        XCTAssertEqual(presenter.events, [])
        var input = RecorderInput(live: services.live, style: .classic, selectedModeName: nil, modeChangedName: nil)
        input.phase = .idle
        XCTAssertEqual(RecorderViewModel.reduce(input).screen, .result)
    }

    func testAlwaysCloseHidesAnUnconfirmedPaste() {
        let services = makeServices(closeAfterResult: true)
        let presenter = FakeRecorderPresenter()
        services.recorderUI = presenter

        RecorderUIParticipant(services: services).didFinish(finished(.copiedOnly))

        XCTAssertNil(services.live.resultText)
        XCTAssertEqual(presenter.events, ["hide"])
    }

    func testNothingHeardShowsNoAudioAndClearsItself() async {
        let services = makeServices()
        let presenter = FakeRecorderPresenter()
        services.recorderUI = presenter
        let participant = RecorderUIParticipant(services: services)
        participant.errorDismissDelay = 0.05

        participant.didFinish(finished(.empty, text: ""))

        XCTAssertEqual(services.live.errorText, RecorderViewModel.noAudioMessage)
        XCTAssertNil(services.live.resultText)
        XCTAssertEqual(presenter.events, [])

        // The controller is back to idle by the time the banner times out.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(services.live.errorText)
    }

    func testANewerErrorIsNotClearedByAnOlderTimeout() async {
        let services = makeServices()
        let participant = RecorderUIParticipant(services: services)
        participant.errorDismissDelay = 0.05

        participant.didFinish(finished(.failed("first")))
        services.live.errorText = "second"
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(services.live.errorText, "second")
    }

    func testFailureShowsTheMessage() {
        let services = makeServices()
        RecorderUIParticipant(services: services).didFinish(finished(.failed("Model not ready")))
        XCTAssertEqual(services.live.errorText, "Model not ready")
    }

    func testCancelHidesAndClearsEverything() {
        let services = makeServices()
        let presenter = FakeRecorderPresenter()
        services.recorderUI = presenter
        services.live.cancelGuardShown = true
        services.live.modeSwitcherShown = true
        services.live.resultText = "x"
        services.live.errorText = "y"

        RecorderUIParticipant(services: services).didCancel(DictationSession(trigger: .pushToTalk))

        XCTAssertFalse(services.live.cancelGuardShown)
        XCTAssertFalse(services.live.modeSwitcherShown)
        XCTAssertNil(services.live.resultText)
        XCTAssertNil(services.live.errorText)
        XCTAssertEqual(presenter.events, ["hide"])
    }

    func testSnapshotCopiesEveryLiveField() {
        let services = makeServices()
        let live = services.live
        let start = Date(timeIntervalSince1970: 5)
        live.phase = .recording
        live.modeName = "Code"
        live.destinationLabel = "Xcode"
        live.startedAt = start
        live.levels = [0.3]
        live.silentMicDevice = "Mic"
        live.lidWarning = "Lid"
        live.confirmedText = "a"
        live.hypothesisText = "b"
        live.selectionChip = "s"
        live.clipboardChip = "c"
        live.resultText = "r"
        live.errorText = "e"
        live.modeSwitcherShown = true
        live.cancelGuardShown = true
        live.processingProgress = 0.4

        let input = RecorderInput(live: live, style: .mini, selectedModeName: "General", modeChangedName: "Email")
        XCTAssertEqual(input, RecorderInput(
            phase: .recording, modeName: "Code", destinationLabel: "Xcode", startedAt: start,
            levels: [0.3], silentMicDevice: "Mic", lidWarning: "Lid", confirmedText: "a",
            hypothesisText: "b", selectionChip: "s", clipboardChip: "c", resultText: "r",
            errorText: "e", modeSwitcherShown: true, cancelGuardShown: true, processingProgress: 0.4,
            style: .mini, selectedModeName: "General", modeChangedName: "Email"
        ))
    }
}

/// Records the presenter calls the participant makes.
@MainActor
final class FakeRecorderPresenter: RecorderUIPresenting {
    var events: [String] = []
    func showRecorder() { events.append("show") }
    func hideRecorder() { events.append("hide") }
    func showLidClosedWarning() { events.append("lid") }
}
