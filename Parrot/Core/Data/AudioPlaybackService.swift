import AVFoundation
import Foundation
import Observation

/// Plays one recording's audio at a time for the history view. [DATA]
///
/// Starting another recording stops the current one. A missing file logs
/// "Audio file not found" and does not start.
@MainActor
@Observable
final class AudioPlaybackService {

    /// The history entry playing or paused, if any.
    private(set) var currentID: Int64?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    init() {}

    /// Plays `url` for entry `id`, or resumes it when it is the paused one.
    func play(url: URL, id: Int64) {
        errorMessage = nil
        if currentID == id, let player {
            player.play()
            isPlaying = true
            startTimer()
            return
        }
        stop()
        guard FileManager.default.fileExists(atPath: url.path) else {
            diagLog("[Parrot:History] Audio file not found: \(url.lastPathComponent)")
            errorMessage = "Audio file not found"
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            currentID = id
            duration = player.duration
            currentTime = 0
            player.play()
            isPlaying = true
            startTimer()
        } catch {
            diagLog("[Parrot:History] Could not play audio: \(error)")
            errorMessage = "Could not play this recording"
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func toggle(url: URL, id: Int64) {
        if currentID == id && isPlaying {
            pause()
        } else {
            play(url: url, id: id)
        }
    }

    /// Jumps to `time` seconds in the current recording.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        currentID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    /// Stops playback when `id` is the recording being deleted.
    func stopIfPlaying(_ ids: Set<Int64>) {
        if let currentID, ids.contains(currentID) { stop() }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying && isPlaying {
            isPlaying = false
            timer?.invalidate()
            if currentTime >= duration - 0.05 { currentTime = 0 }
        }
    }
}
