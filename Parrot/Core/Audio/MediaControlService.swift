import AppKit
import CoreAudio
import Foundation

/// Pauses and resumes media apps. MediaRemote is closed to normal apps on
/// current macOS, so the real one drives Music and Spotify by AppleScript;
/// tests pass a fake. [AUD]
protocol MediaPlayerControl: Sendable {
    /// Pauses the supported apps that are running and playing. Returns the
    /// bundle ids it paused.
    func pausePlaying() async -> Set<String>
    func resume(_ bundleIDs: Set<String>) async
}

/// Music and Spotify through AppleScript, only when the app is already
/// running (a script would otherwise launch it). [AUD]
struct AppleScriptMediaPlayers: MediaPlayerControl {
    static let bundleIDs = ["com.apple.Music", "com.spotify.client"]

    var runner = AppleScriptRunner(timeout: 3)

    func pausePlaying() async -> Set<String> {
        var paused: Set<String> = []
        for id in Self.bundleIDs where Self.isRunning(id) {
            let script = """
            tell application id "\(id)"
                if player state is playing then
                    pause
                    return "paused"
                end if
            end tell
            return ""
            """
            do {
                let output = try await runner.run(script)
                if output.trimmingCharacters(in: .whitespacesAndNewlines) == "paused" {
                    paused.insert(id)
                }
            } catch {
                diagLog("[Parrot:Media] Could not pause media (\(id)): \(error.localizedDescription)")
            }
        }
        return paused
    }

    func resume(_ bundleIDs: Set<String>) async {
        for id in bundleIDs.sorted() where Self.isRunning(id) {
            do {
                _ = try await runner.run("tell application id \"\(id)\" to play")
            } catch {
                diagLog("[Parrot:Media] Could not play media (\(id)): \(error.localizedDescription)")
            }
        }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Pauses, ducks or mutes other audio while recording and restores it
/// afterwards (au F14 to F16). [AUD]
///
/// `begin` fades the output down (0.25 s, or 0.4 s on Bluetooth) and, for
/// `.pause`, pauses Music and Spotify; with `.pause` everything else is
/// ducked only while some app is actually playing. `end` restores: at once
/// on wired or built-in output, and on Bluetooth after the output device
/// changes (the headset leaving its call profile) or 4 s, whichever comes
/// first. Every begin and end bumps `generation`, so delayed work from an
/// older recording never lands in a newer one, and a recording that starts
/// before the previous restore finished keeps the original volume to
/// restore later.
@MainActor
final class MediaControlService {

    /// One recording's suppression; `end(_:)` restores it once.
    final class Token {
        let behavior: PlaybackBehavior
        let generation: Int
        fileprivate(set) var isRestored = false

        fileprivate init(behavior: PlaybackBehavior, generation: Int) {
            self.behavior = behavior
            self.generation = generation
        }
    }

    enum FadeState {
        case fadeOut
        case atRest
        case fadeIn
    }

    /// The output state to put back, kept until a restore completes.
    private struct Saved {
        let device: AudioDeviceID
        let volume: Float
        let wasMuted: Bool
        let bluetooth: Bool
        /// The volume was lowered (or muted) by a suppression.
        var adjusted = false
        var muted = false
    }

    private(set) var generation = 0
    private(set) var fadeState: FadeState = .atRest
    /// True while a Bluetooth restore waits for the output device to change.
    private(set) var awaitingOutputChange = false

    private let output: OutputVolumeControl
    private let players: MediaPlayerControl
    private let scheduler: DelayScheduler
    private var saved: Saved?
    private var pausedApps: Task<Set<String>, Never>?
    private var pendingWork: [ScheduledWork] = []

    init(output: OutputVolumeControl? = nil, players: MediaPlayerControl? = nil, scheduler: DelayScheduler? = nil) {
        self.output = output ?? CoreAudioHardware()
        self.players = players ?? AppleScriptMediaPlayers()
        self.scheduler = scheduler ?? TaskDelayScheduler()
    }

    func start(services: AppServices) {}

    // MARK: - Suppression

    /// Applies `behavior` for a recording that is starting. Returns nil for
    /// `.keepPlaying`.
    func begin(_ behavior: PlaybackBehavior) -> Token? {
        guard behavior != .keepPlaying else { return nil }
        generation += 1
        cancelPendingWork()
        awaitingOutputChange = false

        if behavior == .pause {
            pauseMediaApps()
        }

        guard let device = saved?.device ?? output.defaultOutputDevice() else {
            return Token(behavior: behavior, generation: generation)
        }
        var state = saved ?? Saved(
            device: device,
            volume: output.volume(of: device) ?? FadeSchedule.assumedOriginalVolume,
            wasMuted: output.isMuted(device) ?? false,
            bluetooth: output.isBluetooth(device)
        )

        // `.pause` ducks "everything else" only when something is playing;
        // a volume still lowered by the previous recording stays lowered.
        let shouldAdjust = behavior != .pause || state.adjusted || output.isRunningSomewhere(device)
        if shouldAdjust, let target = PlaybackResolution.targetVolume(for: behavior, currentVolume: state.volume) {
            var from = output.volume(of: device) ?? state.volume
            if state.muted && behavior != .mute {
                output.setMuted(state.wasMuted, of: device)
                state.muted = false
                from = 0
            }
            state.adjusted = true
            saved = state
            fade(device, from: from, to: target, direction: .fadeOut, bluetooth: state.bluetooth) { [weak self] in
                guard let self, behavior == .mute else { return }
                if self.output.setMuted(true, of: device) {
                    self.saved?.muted = true
                } else {
                    diagLog("[Parrot:Media] Could not mute output device; mute is not supported on current output channels")
                }
            }
        } else {
            saved = state
        }
        return Token(behavior: behavior, generation: generation)
    }

    /// Restores what `token` changed, unless a newer recording took over.
    func end(_ token: Token) {
        guard !token.isRestored else { return }
        token.isRestored = true
        guard token.generation == generation else {
            diagLog("[Parrot:Media] Ignoring a stale playback restore")
            return
        }
        generation += 1
        cancelPendingWork()

        guard let state = saved, state.adjusted, state.bluetooth else {
            diagLog("[Parrot:Media] Default device is normal")
            restore()
            return
        }
        diagLog("[Parrot:Media] Default device is Bluetooth")
        awaitingOutputChange = true
        let current = generation
        pendingWork.append(scheduler.schedule(after: FadeSchedule.bluetoothRestoreTimeout) { [weak self] in
            guard let self, self.generation == current, self.awaitingOutputChange else { return }
            diagLog("[Parrot:Media] Timer Fade in Triggered")
            self.restore()
        })
    }

    /// The default output device changed (AudioDeviceService forwards it).
    func defaultOutputDidChange() {
        guard awaitingOutputChange else { return }
        diagLog("[Parrot:Media] DeviceObserver Fade in Triggered")
        restore()
    }

    // MARK: - Private

    private func restore() {
        awaitingOutputChange = false
        resumeMediaApps()
        guard let state = saved else { return }
        guard state.adjusted else {
            saved = nil
            return
        }
        if state.muted {
            output.setMuted(state.wasMuted, of: state.device)
        }
        let from = state.muted ? 0 : (output.volume(of: state.device) ?? FadeSchedule.duckedVolume)
        fade(state.device, from: from, to: state.volume, direction: .fadeIn, bluetooth: state.bluetooth) { [weak self] in
            self?.saved = nil
        }
    }

    /// Schedules the volume steps. Steps from an older generation are dropped.
    private func fade(
        _ device: AudioDeviceID,
        from: Float,
        to: Float,
        direction: FadeSchedule.Direction,
        bluetooth: Bool,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let current = generation
        let lastFadeStep = FadeSchedule.timing(direction, bluetooth: bluetooth).steps - 1
        fadeState = direction == .fadeOut ? .fadeOut : .fadeIn
        for (index, step) in FadeSchedule.steps(from: from, to: to, direction: direction, bluetooth: bluetooth).enumerated() {
            pendingWork.append(scheduler.schedule(after: step.delay) { [weak self] in
                guard let self, self.generation == current else { return }
                if !self.output.setVolume(step.volume, of: device), index == 0 {
                    diagLog("[Parrot:Media] Could not adjust output volume while applying playback suppression")
                }
                if index == lastFadeStep {
                    self.fadeState = .atRest
                    completion?()
                }
            })
        }
    }

    private func cancelPendingWork() {
        pendingWork.forEach { $0.cancel() }
        pendingWork.removeAll()
        fadeState = .atRest
    }

    /// Pauses media apps, adding to anything an unrestored recording paused.
    private func pauseMediaApps() {
        let earlier = pausedApps
        let players = self.players
        pausedApps = Task {
            let before = await earlier?.value ?? []
            return before.union(await players.pausePlaying())
        }
    }

    /// Resumes what was paused. If a new recording started meanwhile, the
    /// apps stay paused and are handed to it.
    private func resumeMediaApps() {
        guard let task = pausedApps else { return }
        pausedApps = nil
        let current = generation
        let players = self.players
        Task { [weak self] in
            let apps = await task.value
            guard !apps.isEmpty else { return }
            if let self, self.generation != current {
                let earlier = self.pausedApps
                self.pausedApps = Task { (await earlier?.value ?? []).union(apps) }
                return
            }
            await players.resume(apps)
        }
    }
}
