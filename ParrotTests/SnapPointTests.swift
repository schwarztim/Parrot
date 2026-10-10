import CoreGraphics
import XCTest

@testable import Parrot

/// The Mini pill's snap grid: ids across screens, placement inside each
/// screen, the nearest point, the missing-screen fallback and where the
/// attached panel opens. Also the Mini presentation and hints. Moving real
/// windows needs a GUI session and is not covered here.
@MainActor
final class SnapPointTests: XCTestCase {

    private let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let side = CGRect(x: 1440, y: 100, width: 1920, height: 1055)
    private let pill = CGSize(width: 140, height: 40)

    // MARK: - Grid

    func testNinePointsPerScreenWithStableIDs() {
        let points = SnapGrid.points(screens: [main, side])
        XCTAssertEqual(points.count, 18)
        XCTAssertEqual(points.map(\.id), Array(0..<18))
        XCTAssertEqual(points.filter { $0.screenIndex == 1 }.map(\.id), Array(9..<18))
        XCTAssertTrue(points.filter { $0.screenIndex == 1 }.allSatisfy { $0.screen == side })
    }

    func testDefaultIDIsBottomCenterOfTheFirstScreen() {
        let point = SnapGrid.resolve(id: 0, in: SnapGrid.points(screens: [main, side]))
        XCTAssertEqual(point?.screenIndex, 0)
        XCTAssertEqual(point?.column, .center)
        XCTAssertEqual(point?.row, .bottom)
        XCTAssertEqual(point.map { SnapGrid.origin(of: $0, size: pill) }, CGPoint(x: 650, y: 20))
    }

    func testOriginsSitInsideTheScreenAtEachEdge() {
        let points = SnapGrid.points(screens: [side])
        for point in points {
            let origin = SnapGrid.origin(of: point, size: pill)
            let frame = CGRect(origin: origin, size: pill)
            XCTAssertTrue(side.contains(frame), "\(point.column) \(point.row) leaves the screen")
        }
        let topRight = points.first { $0.column == .right && $0.row == .top }!
        XCTAssertEqual(SnapGrid.origin(of: topRight, size: pill), CGPoint(x: 1440 + 1920 - 20 - 140, y: 100 + 1055 - 20 - 40))
        let centerLeft = points.first { $0.column == .left && $0.row == .center }!
        XCTAssertEqual(SnapGrid.origin(of: centerLeft, size: pill), CGPoint(x: 1460, y: 607.5))
    }

    func testNearestPicksTheClosestPointOnAnyScreen() {
        let points = SnapGrid.points(screens: [main, side])
        // Dropped near the right screen's top left corner.
        let nearest = SnapGrid.nearest(to: CGPoint(x: 1530, y: 1100), size: pill, in: points)
        XCTAssertEqual(nearest?.screenIndex, 1)
        XCTAssertEqual(nearest?.column, .left)
        XCTAssertEqual(nearest?.row, .top)
        XCTAssertEqual(nearest?.id, 15)

        // Dropped just above the main screen's bottom center.
        let bottom = SnapGrid.nearest(to: CGPoint(x: 700, y: 90), size: pill, in: points)
        XCTAssertEqual(bottom?.id, 0)
        XCTAssertNil(SnapGrid.nearest(to: .zero, size: pill, in: []))
    }

    func testEngagedOnlyWithinThirtyPoints() {
        let point = SnapGrid.resolve(id: 0, in: SnapGrid.points(screens: [main]))!
        let center = SnapGrid.center(of: point, size: pill)
        XCTAssertTrue(SnapGrid.isEngaged(point, center: CGPoint(x: center.x + 20, y: center.y + 20), size: pill))
        XCTAssertFalse(SnapGrid.isEngaged(point, center: CGPoint(x: center.x + 40, y: center.y), size: pill))
    }

    func testMissingScreenFallsBackToTheFirstPoint() {
        let both = SnapGrid.points(screens: [main, side])
        XCTAssertEqual(SnapGrid.resolve(id: 10, in: both)?.screenIndex, 1)

        // The side screen is unplugged: its ids are gone.
        let mainOnly = SnapGrid.points(screens: [main])
        let fallback = SnapGrid.resolve(id: 10, in: mainOnly)
        XCTAssertEqual(fallback?.id, 0)
        XCTAssertEqual(fallback?.screen, main)
        XCTAssertNil(SnapGrid.resolve(id: 3, in: []))
        XCTAssertEqual(SnapGrid.resolve(id: -1, in: mainOnly)?.id, 0)
    }

    // MARK: - Attached Panel

    func testTopRowOpensBelowAndOthersAbove() {
        let points = SnapGrid.points(screens: [main])
        for point in points {
            XCTAssertEqual(point.auxPin, point.row == .top ? .below : .above)
        }
    }

    func testAuxPanelCentersOnThePillAndStaysOnScreen() {
        let pillFrame = CGRect(x: 650, y: 20, width: 140, height: 40)
        let aux = CGSize(width: 300, height: 200)
        XCTAssertEqual(
            SnapGrid.auxOrigin(pill: pillFrame, auxSize: aux, pin: .above, screen: main),
            CGPoint(x: 570, y: 68)
        )
        // Below a top-right pill: pushed left to stay on screen.
        let topRight = CGRect(x: 1280, y: 815, width: 140, height: 40)
        XCTAssertEqual(
            SnapGrid.auxOrigin(pill: topRight, auxSize: aux, pin: .below, screen: main),
            CGPoint(x: 1140, y: 607)
        )
    }

    // MARK: - Mini Presentation

    private func state(_ configure: (inout RecorderInput) -> Void) -> RecorderViewState {
        var input = RecorderInput()
        input.style = .mini
        configure(&input)
        return RecorderViewModel.reduce(input)
    }

    func testAlwaysShowKeepsTheIdlePill() {
        let shown = state { $0.alwaysShowMini = true }
        XCTAssertEqual(shown.screen, .idle)
        XCTAssertTrue(shown.isVisible)
        XCTAssertEqual(shown.primaryButton, .none)
        XCTAssertEqual(MiniRecorderLogic.presentation(for: shown), MiniPresentation(showsPill: true, activity: .idle, aux: nil, passiveHint: nil))

        let hidden = state { $0.alwaysShowMini = false }
        XCTAssertEqual(hidden.screen, .hidden)
        XCTAssertEqual(MiniRecorderLogic.presentation(for: hidden), .hidden)

        // Always show applies only to the Mini style.
        let classic = state {
            $0.style = .classic
            $0.alwaysShowMini = true
        }
        XCTAssertEqual(classic.screen, .hidden)
    }

    func testAuxFollowsTheOverlay() {
        let recording = state { $0.phase = .recording }
        XCTAssertEqual(MiniRecorderLogic.presentation(for: recording).activity, .recording)
        XCTAssertNil(MiniRecorderLogic.presentation(for: recording).aux)

        let guardState = state {
            $0.phase = .recording
            $0.cancelGuardShown = true
        }
        XCTAssertEqual(MiniRecorderLogic.presentation(for: guardState).aux, .discard)

        let switcher = state {
            $0.phase = .recording
            $0.modeSwitcherShown = true
        }
        let switcherPresentation = MiniRecorderLogic.presentation(for: switcher)
        XCTAssertEqual(switcherPresentation.aux, .modeList)
        XCTAssertEqual(switcherPresentation.activity, .recording)

        let result = state { $0.resultText = "Hello" }
        XCTAssertEqual(MiniRecorderLogic.presentation(for: result).aux, .result)

        let error = state { $0.errorText = RecorderViewModel.noAudioMessage }
        XCTAssertEqual(MiniRecorderLogic.presentation(for: error).aux, .error)

        let processing = state { $0.phase = .processing }
        XCTAssertEqual(MiniRecorderLogic.presentation(for: processing).activity, .processing)
    }

    func testModeChangeShowsTheSelectedHint() {
        let changed = state {
            $0.alwaysShowMini = true
            $0.modeChangedName = "Email"
        }
        XCTAssertEqual(changed.screen, .modeChanged)
        XCTAssertEqual(MiniRecorderLogic.presentation(for: changed).passiveHint, .modeSelected("Email"))
        XCTAssertEqual(MiniHint.modeSelected("Email").title, "Email mode selected")
    }

    func testHoverHints() {
        XCTAssertEqual(MiniRecorderLogic.hint(for: .record, activity: .idle, modeName: "Note"), .start)
        XCTAssertEqual(MiniRecorderLogic.hint(for: .record, activity: .recording, modeName: "Note"), .stop)
        XCTAssertNil(MiniRecorderLogic.hint(for: .record, activity: .processing, modeName: "Note"))
        XCTAssertEqual(MiniRecorderLogic.hint(for: .mode, activity: .idle, modeName: "Note"), .mode("Note"))
        XCTAssertEqual(MiniRecorderLogic.hint(for: .expand, activity: .recording, modeName: "Note"), .expand)
        XCTAssertEqual(MiniHint.mode("Note").title, "Note mode active")
        XCTAssertEqual(MiniHint.start.title, "Start recording")
        XCTAssertEqual(MiniHint.cancel.title, "Discard recording?")
        XCTAssertLessThan(MiniRecorderLogic.barCount(for: .idle), MiniRecorderLogic.barCount(for: .recording))
    }

    // MARK: - Settings

    func testSnapPointAndAlwaysShowPersist() {
        let suite = "SnapPointTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertTrue(first.recorder.alwaysShowMini)
        XCTAssertEqual(first.recorder.snapPointID, 0)
        XCTAssertNil(defaults.object(forKey: "parrot.recorder.snapPointID"))
        first.recorder.snapPointID = 10
        first.recorder.alwaysShowMini = false

        let second = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertEqual(second.recorder.snapPointID, 10)
        XCTAssertFalse(second.recorder.alwaysShowMini)
    }
}
