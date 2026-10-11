@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Live text for one recording on FluidAudio's sliding-window streaming
/// recognizer, sharing the batch engine's loaded Parakeet models. [ASR]
///
/// Display only: the pasted text always comes from the full batch pass
/// after the recording stops. Audio arrives on the audio thread through
/// `append`, which only queues it; a task feeds the recognizer in order.
final class ParakeetLiveStream: LiveTranscriptionStream, @unchecked Sendable {

    /// Short windows so text appears while a dictation is still short: the
    /// first update lands after 2.5 s of audio, then every 1.5 s. Confirmed
    /// text needs 10 s of context; until then everything is hypothesis.
    static let config = SlidingWindowAsrConfig(
        chunkSeconds: 1.5,
        hypothesisChunkSeconds: 1.0,
        leftContextSeconds: 4.0,
        rightContextSeconds: 1.0,
        minContextForConfirmation: 10.0,
        confirmationThreshold: 0.80
    )

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioFrame.sampleRate, channels: 1, interleaved: false
    )

    private let manager: SlidingWindowAsrManager
    private let audio: AsyncStream<[Float]>.Continuation
    private let feeder: Task<Void, Never>
    private let listener: Task<Void, Never>

    /// Opens a stream on already loaded models.
    static func start(
        models: AsrModels,
        version: ParakeetVersion,
        language: Language?,
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) async throws -> ParakeetLiveStream {
        var config = Self.config
        if version == .v2 {
            // V2's blank token id; FluidAudio's default is V3's.
            config = config.applying(tdtConfig: TdtConfig(blankId: 1024))
        }
        config = config.applying(language: language)

        let manager = SlidingWindowAsrManager(config: config)
        try await manager.loadModels(models)
        // The getter makes a new stream each time: read it exactly once.
        let updates = await manager.transcriptionUpdates
        try await manager.startStreaming(source: .microphone)
        return ParakeetLiveStream(manager: manager, updates: updates, onUpdate: onUpdate)
    }

    private init(
        manager: SlidingWindowAsrManager,
        updates: AsyncStream<SlidingWindowTranscriptionUpdate>,
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) {
        self.manager = manager
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.audio = continuation
        feeder = Task {
            for await samples in stream {
                guard let buffer = Self.buffer(from: samples) else { continue }
                await manager.streamAudio(buffer)
            }
        }
        listener = Task {
            for await _ in updates {
                let confirmed = await manager.confirmedTranscript
                let hypothesis = await manager.volatileTranscript
                onUpdate(LiveTranscriptUpdate(confirmed: confirmed, hypothesis: hypothesis))
            }
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        audio.yield(samples)
    }

    func finish() async throws -> String {
        audio.finish()
        await feeder.value
        defer { listener.cancel() }
        return try await manager.finish()
    }

    func cancel() async {
        audio.finish()
        feeder.cancel()
        listener.cancel()
        await manager.cancel()
    }

    private static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
