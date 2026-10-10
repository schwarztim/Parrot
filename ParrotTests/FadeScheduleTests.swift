import XCTest

@testable import Parrot

/// Fade timings and Bluetooth re-applies for ducking and muting.
final class FadeScheduleTests: XCTestCase {

    func testNormalFadeOutIsTenStepsOverQuarterSecond() {
        let steps = FadeSchedule.steps(from: 0.8, to: 0.15, direction: .fadeOut, bluetooth: false)
        XCTAssertEqual(steps.count, 10)
        XCTAssertEqual(steps.first!.delay, 0.025, accuracy: 1e-9)
        XCTAssertEqual(steps.last!.delay, 0.25, accuracy: 1e-9)
        XCTAssertEqual(steps.last!.volume, 0.15)
        XCTAssertEqual(steps[4].volume, 0.8 + (0.15 - 0.8) * 0.5, accuracy: 1e-6)
        XCTAssertEqual(steps.map(\.volume), steps.map(\.volume).sorted(by: >), "monotonic")
    }

    func testBluetoothFadeOutIsSixteenStepsOverPointFourPlusReapplies() {
        let steps = FadeSchedule.steps(from: 0.5, to: 0.15, direction: .fadeOut, bluetooth: true)
        XCTAssertEqual(steps.count, 16 + 5)
        XCTAssertEqual(steps[15].delay, 0.4, accuracy: 1e-9)
        let reapplies = steps.suffix(5)
        XCTAssertEqual(reapplies.map(\.delay), [0.48, 0.58, 0.72, 0.9, 1.15].map { $0 }, accuracy: 1e-9)
        XCTAssertTrue(reapplies.allSatisfy { $0.volume == 0.15 })
    }

    func testFadeInTimings() {
        XCTAssertEqual(FadeSchedule.timing(.fadeIn, bluetooth: false).duration, 0.5)
        XCTAssertEqual(FadeSchedule.timing(.fadeIn, bluetooth: false).steps, 10)
        XCTAssertEqual(FadeSchedule.timing(.fadeIn, bluetooth: true).duration, 0.65)
        XCTAssertEqual(FadeSchedule.timing(.fadeIn, bluetooth: true).steps, 16)
        let steps = FadeSchedule.steps(from: 0.15, to: 0.7, direction: .fadeIn, bluetooth: false)
        XCTAssertEqual(steps.last!.volume, 0.7)
        XCTAssertEqual(steps.last!.delay, 0.5, accuracy: 1e-9)
    }

    func testSpecConstants() {
        XCTAssertEqual(FadeSchedule.duckedVolume, 0.15)
        XCTAssertEqual(FadeSchedule.assumedOriginalVolume, 0.5)
        XCTAssertEqual(FadeSchedule.bluetoothRestoreTimeout, 4.0)
        XCTAssertEqual(FadeSchedule.bluetoothStabilizationDelays, [0.08, 0.18, 0.32, 0.5, 0.75])
    }
}

private func XCTAssertEqual(
    _ lhs: [TimeInterval], _ rhs: [TimeInterval], accuracy: TimeInterval,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (a, b) in zip(lhs, rhs) {
        XCTAssertEqual(a, b, accuracy: accuracy, file: file, line: line)
    }
}
