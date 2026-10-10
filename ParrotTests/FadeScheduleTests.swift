import CoreAudio
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

/// Fake output device: the real system volume never changes.
final class FakeOutputVolume: OutputVolumeControl {
    var device: AudioDeviceID? = 7
    var volume: Float? = 0.6
    var muted = false
    var bluetooth = false
    var running = true
    private(set) var setVolumeCalls: [Float] = []

    func defaultOutputDevice() -> AudioDeviceID? { device }
    func volume(of device: AudioDeviceID) -> Float? { volume }

    func setVolume(_ volume: Float, of device: AudioDeviceID) -> Bool {
        setVolumeCalls.append(volume)
        self.volume = volume
        return true
    }

    func isMuted(_ device: AudioDeviceID) -> Bool? { muted }

    func setMuted(_ muted: Bool, of device: AudioDeviceID) -> Bool {
        self.muted = muted
        return true
    }

    func isBluetooth(_ device: AudioDeviceID) -> Bool { bluetooth }
    func isRunningSomewhere(_ device: AudioDeviceID) -> Bool { running }
}

/// Fake media apps: nothing real is paused or played.
final class FakeMediaPlayers: MediaPlayerControl, @unchecked Sendable {
    private let lock = NSLock()
    private var playing: Set<String>
    private var _pauseCalls = 0
    private var _resumed: [Set<String>] = []

    init(playing: Set<String>) {
        self.playing = playing
    }

    var pauseCalls: Int { lock.withLock { _pauseCalls } }
    var resumed: [Set<String>] { lock.withLock { _resumed } }

    func pausePlaying() async -> Set<String> {
        lock.withLock {
            _pauseCalls += 1
            let paused = playing
            playing = []
            return paused
        }
    }

    func resume(_ bundleIDs: Set<String>) async {
        lock.withLock {
            _resumed.append(bundleIDs)
            playing.formUnion(bundleIDs)
        }
    }
}

/// Playback suppression with fake output, fake media apps and a manual clock.
@MainActor
final class MediaControlServiceTests: XCTestCase {

    private var output: FakeOutputVolume!
    private var players: FakeMediaPlayers!
    private var clock: AudioTestScheduler!
    private var media: MediaControlService!

    override func setUp() async throws {
        try await super.setUp()
        output = FakeOutputVolume()
        players = FakeMediaPlayers(playing: ["com.apple.Music"])
        clock = AudioTestScheduler()
        media = MediaControlService(output: output, players: players, scheduler: clock)
    }

    /// Lets the media service's tasks run (fake players answer at once).
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testDuckFadesToFifteenPercentAndRestores() throws {
        let token = try XCTUnwrap(media.begin(.duck))
        clock.advance(by: 0.2)
        XCTAssertGreaterThan(output.volume!, 0.15, "still fading")
        clock.advance(by: 0.05)
        XCTAssertEqual(output.volume, 0.15)
        XCTAssertEqual(output.setVolumeCalls.count, 10)

        media.end(token)
        clock.advance(by: 0.49)
        XCTAssertLessThan(output.volume!, 0.6)
        clock.advance(by: 0.01)
        XCTAssertEqual(output.volume, 0.6)
        XCTAssertEqual(media.fadeState, .atRest)
    }

    func testDuckNeverRaisesAQuietVolume() throws {
        output.volume = 0.1
        let token = try XCTUnwrap(media.begin(.duck))
        clock.advance(by: 1)
        XCTAssertEqual(output.volume, 0.1)
        media.end(token)
        clock.advance(by: 1)
        XCTAssertEqual(output.volume, 0.1)
    }

    func testUnreadableVolumeRestoresToHalf() throws {
        output.volume = nil
        let token = try XCTUnwrap(media.begin(.duck))
        clock.advance(by: 1)
        output.volume = nil
        media.end(token)
        clock.advance(by: 1)
        XCTAssertEqual(output.volume, 0.5)
    }

    func testMuteFadesToZeroThenMutesAndRestores() throws {
        let token = try XCTUnwrap(media.begin(.mute))
        clock.advance(by: 0.25)
        XCTAssertEqual(output.volume, 0)
        XCTAssertTrue(output.muted)

        media.end(token)
        XCTAssertFalse(output.muted)
        clock.advance(by: 0.5)
        XCTAssertEqual(output.volume, 0.6)
    }

    func testKeepPlayingChangesNothing() async {
        XCTAssertNil(media.begin(.keepPlaying))
        clock.advance(by: 1)
        XCTAssertEqual(output.setVolumeCalls, [])
        XCTAssertEqual(players.pauseCalls, 0)
    }

    func testPausePausesMusicAndResumesIt() async throws {
        output.running = false
        let token = try XCTUnwrap(media.begin(.pause))
        await waitUntil { players.pauseCalls == 1 }
        XCTAssertEqual(players.pauseCalls, 1)
        clock.advance(by: 1)
        XCTAssertEqual(output.setVolumeCalls, [], "nothing else playing, nothing ducked")

        media.end(token)
        await waitUntil { !players.resumed.isEmpty }
        XCTAssertEqual(players.resumed, [["com.apple.Music"]])
    }

    func testPauseDucksOtherAudioWhenSomethingPlays() throws {
        output.running = true
        let token = try XCTUnwrap(media.begin(.pause))
        clock.advance(by: 0.25)
        XCTAssertEqual(output.volume, 0.15)
        media.end(token)
        clock.advance(by: 0.5)
        XCTAssertEqual(output.volume, 0.6)
    }

    func testNothingPlayingMeansNothingResumed() async throws {
        players = FakeMediaPlayers(playing: [])
        media = MediaControlService(output: output, players: players, scheduler: clock)
        let token = try XCTUnwrap(media.begin(.pause))
        await waitUntil { players.pauseCalls == 1 }
        media.end(token)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(players.resumed, [])
    }

    func testBluetoothFadeIsSlowerAndReapplied() throws {
        output.bluetooth = true
        _ = try XCTUnwrap(media.begin(.duck))
        clock.advance(by: 0.39)
        XCTAssertGreaterThan(output.volume!, 0.15)
        clock.advance(by: 0.01)
        XCTAssertEqual(output.volume, 0.15)
        clock.advance(by: 1)
        XCTAssertEqual(output.setVolumeCalls.count, 16 + 5)
        XCTAssertEqual(output.setVolumeCalls.suffix(6), [0.15, 0.15, 0.15, 0.15, 0.15, 0.15])
    }

    func testBluetoothRestoreWaitsForTheOutputDeviceToChange() throws {
        output.bluetooth = true
        let token = try XCTUnwrap(media.begin(.duck))
        clock.advance(by: 2)
        media.end(token)
        XCTAssertTrue(media.awaitingOutputChange)
        clock.advance(by: 3)
        XCTAssertEqual(output.volume, 0.15, "waits for the headset")

        media.defaultOutputDidChange()
        clock.advance(by: 0.65)
        XCTAssertEqual(output.volume, 0.6)
        let calls = output.setVolumeCalls.count

        clock.advance(by: 5)
        media.defaultOutputDidChange()
        clock.advance(by: 2)
        XCTAssertEqual(output.setVolumeCalls.count, calls + 5, "only the re-applies follow; restore runs once")
        XCTAssertEqual(output.volume, 0.6)
    }

    func testBluetoothRestoreFallsBackAfterFourSeconds() throws {
        output.bluetooth = true
        let token = try XCTUnwrap(media.begin(.duck))
        clock.advance(by: 2)
        media.end(token)
        clock.advance(by: 3.99)
        XCTAssertEqual(output.volume, 0.15)
        clock.advance(by: 0.01 + 0.65)
        XCTAssertEqual(output.volume, 0.6)
    }

    func testNewRecordingBeforeTheRestoreKeepsTheOriginalVolume() throws {
        output.bluetooth = true
        let first = try XCTUnwrap(media.begin(.duck))
        clock.advance(by: 2)
        media.end(first)

        let second = try XCTUnwrap(media.begin(.duck))
        clock.advance(by: 10)
        XCTAssertEqual(output.volume, 0.15, "the first recording's restore never lands mid-recording")

        media.end(second)
        media.defaultOutputDidChange()
        clock.advance(by: 2)
        XCTAssertEqual(output.volume, 0.6, "restores the volume from before the first recording")
    }

    func testStaleTokenIsIgnored() throws {
        let first = try XCTUnwrap(media.begin(.duck))
        clock.advance(by: 1)
        let second = try XCTUnwrap(media.begin(.duck))
        clock.advance(by: 1)

        media.end(first)
        clock.advance(by: 1)
        XCTAssertEqual(output.volume, 0.15, "an older recording cannot restore")

        media.end(second)
        media.end(second)
        clock.advance(by: 1)
        XCTAssertEqual(output.volume, 0.6)
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
