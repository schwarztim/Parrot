import XCTest

@testable import Parrot

/// The start cue plays right after the mic opens, so the mic can hear it.
/// This mixes each start cue (Simple 0.33 s, Classic 1.14 s, rendered at
/// 16 kHz) into the start of the speech fixture, at the default cue volume
/// with no acoustic loss (worst case) and 20 dB below it, both over the
/// first words and in a second of silence before them, and compares
/// Parakeet's transcript with the clean one. Result (2026-10-10): identical
/// in every case, so the recording keeps the cue and nothing is zeroed.
/// A press with no speech hears only the cue: Silero finds no speech in it,
/// so the short-clip gate ends the dictation, and the one phrase Parakeet
/// makes of a bare cue ("Thank you.") is a silence phrase cleanup drops.
@MainActor
final class StartCueCaptureTests: XCTestCase {

    /// The default cue volume.
    private static let cueVolume: Float = 0.7

    private static func mix(_ cue: [Float], into samples: [Float], at offset: Int, gain: Float) -> [Float] {
        var mixed = samples
        for (index, value) in cue.enumerated() where offset + index < mixed.count {
            mixed[offset + index] = max(-1, min(1, mixed[offset + index] + value * gain))
        }
        return mixed
    }

    func testStartCueDoesNotChangeTheTranscript() async throws {
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        let engine = TranscriptionEngine()
        try await engine.prepareModel()

        let fixture = try ASRFixture.samples()
        let firstLoud = fixture.firstIndex { abs($0) > 0.02 } ?? 0
        print("[Cue] fixture \(String(format: "%.2f", ASRFixture.seconds(fixture)))s, speech starts at \(String(format: "%.3f", Double(firstLoud) / 16_000))s")
        let clean = try await engine.transcribe(fixture)
        print("[Cue] clean: \(clean)")

        let padded = try ASRFixture.padded(seconds: 1)
        let silence = ASRFixture.zeros(seconds: 1.5)
        let vad = VoiceActivityService()
        try await vad.prepare()
        for cue in [SoundCue.start, .startClassic] {
            let tone = ToneSynth.render(cue, sampleRate: 16_000)
            for (label, gain) in [("full", Self.cueVolume), ("-20dB", Self.cueVolume * 0.1)] {
                let overSpeech = try await engine.transcribe(Self.mix(tone, into: fixture, at: 0, gain: gain))
                let beforeSpeech = try await engine.transcribe(Self.mix(tone, into: padded, at: 0, gain: gain))
                XCTAssertEqual(overSpeech.lowercased(), clean.lowercased(), "\(cue.rawValue) \(label) over speech")
                XCTAssertEqual(beforeSpeech.lowercased(), clean.lowercased(), "\(cue.rawValue) \(label) before speech")

                // A press and release with no speech: only the cue was heard.
                let cueOnly = Self.mix(tone, into: silence, at: 0, gain: gain)
                let regions = try await vad.speechRegions(in: cueOnly)
                let speech = regions.reduce(0) { $0 + $1.count }
                let gated = ShortClipGate.shouldSkip(duration: ASRFixture.seconds(cueOnly), speechSamples: speech)
                let cueText = try await engine.transcribe(cueOnly)
                XCTAssertTrue(gated, "\(cue.rawValue) \(label): the cue alone must not count as speech")
                XCTAssertTrue(
                    cueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || HallucinationFilter.isHallucination(cueText, speechSeconds: Double(speech) / 16_000),
                    "a cue-only clip must not produce text: \(cueText)"
                )
                print("[Cue] \(cue.rawValue) \(String(format: "%.2f", ASRFixture.seconds(tone)))s \(label): over speech: \(overSpeech) | before speech: \(beforeSpeech) | cue only: speech \(String(format: "%.2f", Double(speech) / 16_000))s gated=\(gated) text=\"\(cueText)\"")
            }
        }
    }
}
