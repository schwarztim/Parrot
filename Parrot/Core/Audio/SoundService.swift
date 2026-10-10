import AppKit
import AVFoundation
import Foundation

/// Recording cues: Simple and Classic sets synthesized at runtime, volume
/// and preview (au F17, F18). [AUD]
///
/// Cues play through their own output-only AVAudioEngine, separate from
/// the capture engine (it never touches the microphone). The engine stops
/// two seconds after the last cue so it does not hold the output device
/// open. If the engine cannot start, a macOS system sound plays instead.
@MainActor
final class SoundService {

    /// The engine stops this long after the last cue finishes.
    static let idleStopDelay: TimeInterval = 2

    private let format = AVAudioFormat(standardFormatWithSampleRate: ToneSynth.sampleRate, channels: 1)!
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffers: [SoundCue: AVAudioPCMBuffer] = [:]
    private var stopWork: DispatchWorkItem?

    init() {}

    /// Renders every cue once, so the first one plays without delay.
    func start(services: AppServices) {
        for cue in SoundCue.allCases {
            _ = buffer(for: cue)
        }
    }

    /// Plays the cue for `event` when sound effects are on.
    func play(_ event: CueEvent, settings: AudioSettings?) {
        guard let settings,
              let cue = CueSelection.cue(for: event, theme: settings.soundTheme, enabled: settings.soundEffectsEnabled)
        else { return }
        play(cue, volume: Float(settings.soundEffectsVolume))
    }

    /// The settings preview buttons: plays the current theme's cue even
    /// while sound effects are off.
    func preview(_ event: CueEvent, settings: AudioSettings) {
        guard let cue = CueSelection.cue(for: event, theme: settings.soundTheme, enabled: true) else { return }
        play(cue, volume: Float(settings.soundEffectsVolume))
    }

    func play(_ cue: SoundCue, volume: Float) {
        guard let buffer = buffer(for: cue) else { return }
        do {
            let player = try runningPlayer()
            stopWork?.cancel()
            player.volume = max(0, min(volume, 1))
            player.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.scheduleIdleStop() }
                }
            }
            if !player.isPlaying {
                player.play()
            }
        } catch {
            diagLog("[Parrot:Sound] Cue engine failed (\(error)); using a system sound")
            let sound = NSSound(named: Self.fallbackSoundName(for: cue))
            sound?.volume = max(0, min(volume, 1))
            sound?.play()
        }
    }

    static func fallbackSoundName(for cue: SoundCue) -> String {
        switch cue {
        case .start, .startClassic: return "Tink"
        case .stop, .stopClassic: return "Pop"
        case .noResult: return "Basso"
        }
    }

    // MARK: - Private

    private func buffer(for cue: SoundCue) -> AVAudioPCMBuffer? {
        if let cached = buffers[cue] { return cached }
        let samples = ToneSynth.render(cue)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffers[cue] = buffer
        return buffer
    }

    private func runningPlayer() throws -> AVAudioPlayerNode {
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        if let existing = self.engine, let existingPlayer = self.player {
            engine = existing
            player = existingPlayer
        } else {
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            self.engine = engine
            self.player = player
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        return player
    }

    private func scheduleIdleStop() {
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine, engine.isRunning else { return }
                self.player?.stop()
                engine.stop()
            }
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleStopDelay, execute: work)
    }
}
