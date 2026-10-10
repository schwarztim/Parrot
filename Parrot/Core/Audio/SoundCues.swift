import Foundation

/// The recording cue set (au F17). Off is `soundEffectsEnabled == false`. [AUD]
enum SoundTheme: String, CaseIterable, Codable, Hashable {
    case simple
    case classic

    var label: String {
        switch self {
        case .simple: return "Simple"
        case .classic: return "Classic"
        }
    }
}

/// One synthesized cue. [AUD]
enum SoundCue: String, CaseIterable {
    case start
    case stop
    case startClassic
    case stopClassic
    /// The recording produced no text (both themes).
    case noResult
}

/// When a cue may play.
enum CueEvent: Equatable {
    /// The mic opened.
    case start
    /// The mic closed.
    case stop
    /// The session ended with this outcome.
    case finish(DictationOutcome)
}

/// Which cue an event plays (au F17, F18). [AUD]
enum CueSelection {
    static func cue(for event: CueEvent, theme: SoundTheme, enabled: Bool) -> SoundCue? {
        guard enabled else { return nil }
        switch event {
        case .start:
            return theme == .classic ? .startClassic : .start
        case .stop:
            return theme == .classic ? .stopClassic : .stop
        case .finish(let outcome):
            return outcome == .empty ? .noResult : nil
        }
    }
}

/// Renders Parrot's own cues from sine partials at runtime, so the app
/// ships no sound files. [AUD]
enum ToneSynth {
    static let sampleRate: Double = 44_100

    private struct Note {
        var frequency: Double
        var start: Double
        var duration: Double
        /// Exponential decay time constant in seconds.
        var decay: Double
        /// Overtones as (frequency ratio, amplitude).
        var partials: [(Double, Double)] = [(1, 1)]
    }

    /// Mono samples, peak 0.8.
    static func render(_ cue: SoundCue, sampleRate: Double = sampleRate) -> [Float] {
        let notes = self.notes(for: cue)
        let length = notes.map { $0.start + $0.duration }.max() ?? 0
        var samples = [Float](repeating: 0, count: Int(length * sampleRate))
        for note in notes {
            add(note, to: &samples, sampleRate: sampleRate)
        }
        let peak = samples.map(abs).max() ?? 0
        if peak > 0 {
            let gain = 0.8 / peak
            samples = samples.map { $0 * gain }
        }
        return samples
    }

    private static func notes(for cue: SoundCue) -> [Note] {
        // Soft glass-like blips for Simple; bell partials (inharmonic 2.76x)
        // for Classic.
        let glass: [(Double, Double)] = [(1, 1), (2, 0.18)]
        let bell: [(Double, Double)] = [(1, 1), (2.76, 0.3), (5.4, 0.08)]
        let low: [(Double, Double)] = [(1, 1), (2, 0.35), (3, 0.12)]
        switch cue {
        case .start:
            return [
                Note(frequency: 740, start: 0, duration: 0.16, decay: 0.05, partials: glass),
                Note(frequency: 988, start: 0.09, duration: 0.24, decay: 0.07, partials: glass),
            ]
        case .stop:
            return [
                Note(frequency: 988, start: 0, duration: 0.16, decay: 0.05, partials: glass),
                Note(frequency: 740, start: 0.09, duration: 0.24, decay: 0.07, partials: glass),
            ]
        case .startClassic:
            return [
                Note(frequency: 523.25, start: 0, duration: 0.7, decay: 0.22, partials: bell),
                Note(frequency: 659.25, start: 0.13, duration: 0.75, decay: 0.24, partials: bell),
                Note(frequency: 783.99, start: 0.26, duration: 0.88, decay: 0.28, partials: bell),
            ]
        case .stopClassic:
            return [
                Note(frequency: 783.99, start: 0, duration: 0.7, decay: 0.22, partials: bell),
                Note(frequency: 659.25, start: 0.13, duration: 0.75, decay: 0.24, partials: bell),
                Note(frequency: 523.25, start: 0.26, duration: 0.88, decay: 0.28, partials: bell),
            ]
        case .noResult:
            return [
                Note(frequency: 392, start: 0, duration: 0.25, decay: 0.09, partials: low),
                Note(frequency: 311.13, start: 0.2, duration: 0.4, decay: 0.13, partials: low),
            ]
        }
    }

    private static func add(_ note: Note, to samples: inout [Float], sampleRate: Double) {
        let first = Int(note.start * sampleRate)
        let count = Int(note.duration * sampleRate)
        let attack = 0.005 * sampleRate
        let release = 0.02 * sampleRate
        for index in 0..<count where first + index < samples.count {
            let t = Double(index) / sampleRate
            var value = 0.0
            for (ratio, amplitude) in note.partials {
                value += amplitude * sin(2 * .pi * note.frequency * ratio * t)
            }
            var envelope = exp(-t / note.decay)
            if Double(index) < attack { envelope *= Double(index) / attack }
            let remaining = Double(count - index)
            if remaining < release { envelope *= remaining / release }
            samples[first + index] += Float(value * envelope)
        }
    }
}
