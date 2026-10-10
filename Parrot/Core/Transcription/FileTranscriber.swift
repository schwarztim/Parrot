import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

// MARK: - FileTranscriber

/// Transcribes an audio or video file through the active mode's pipeline:
/// the "Transcribe File..." menu item, Finder's Open With, and file URLs.
/// The result goes to the clipboard and history (flagged from-file), never
/// pasted. [ASR]
@MainActor
final class FileTranscriber {

    let controller: DictationController
    private var services: AppServices { controller.services }

    init(controller: DictationController) {
        self.controller = controller
    }

    /// File types the picker and Open With accept.
    static let contentTypes: [UTType] = [.audio, .movie]

    /// Runs one file through the pipeline in `mode` (nil: the selected
    /// mode). Returns nil when a dictation is already running.
    @discardableResult
    func transcribe(_ url: URL, mode: Mode? = nil) async -> DictationSession? {
        let mode = mode ?? services.modes?.selectedMode
        diagLog("[Parrot:File] Transcribing \(url.lastPathComponent)")
        services.live.errorText = nil
        services.live.resultText = nil
        services.live.processingProgress = 0
        services.recorderUI?.showRecorder()

        guard let session = await controller.transcribe(file: url, mode: mode) else {
            let message = "Finish the current dictation first, then transcribe the file again."
            services.live.errorText = message
            services.showTransientError(message)
            return nil
        }
        services.live.processingProgress = nil

        switch session.outcome {
        case .failed(let message):
            services.live.errorText = message
            services.showTransientError(message)
        case .empty:
            let message = "No speech found in \(url.lastPathComponent)."
            services.live.errorText = message
            services.showTransientError(message)
        default:
            diagLog("[Parrot:File] Done: \(session.text.count) chars, outcome \(String(describing: session.outcome))")
        }
        return session
    }

    /// Shows the file picker, then transcribes the chosen file.
    func pickAndTranscribe() {
        let panel = NSOpenPanel()
        panel.title = "Select an audio or video file to transcribe"
        panel.prompt = "Transcribe"
        panel.allowedContentTypes = Self.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await transcribe(url) }
    }

    // MARK: - App Entry Points

    /// The running app's transcriber, over the app delegate's controller.
    static var app: FileTranscriber? {
        guard let appState = (NSApp.delegate as? ParrotAppDelegate)?.appState else { return nil }
        return forController(appState.controller)
    }

    /// One transcriber per controller, reused.
    static func forController(_ controller: DictationController) -> FileTranscriber {
        if let existing = shared, existing.controller === controller { return existing }
        let made = FileTranscriber(controller: controller)
        shared = made
        return made
    }

    private static var shared: FileTranscriber?

    /// `TranscriptionRouter.openFile` lands here when no opener is set.
    static func openWithApp(_ url: URL) {
        guard let transcriber = app else {
            diagLog("[Parrot:File] No app state yet, ignoring \(url.lastPathComponent)")
            return
        }
        Task { await transcriber.transcribe(url) }
    }
}

// MARK: - Session Flag

extension DictationSession {
    /// True when the audio came from a file rather than the microphone.
    /// History stores it as the from-file flag (DATA reads it).
    var isFromFile: Bool {
        if case .file = source { return true }
        return false
    }

    /// The file being transcribed, if any.
    var sourceFileURL: URL? {
        if case .file(let url) = source { return url }
        return nil
    }
}

// MARK: - Decoding

/// Decodes any audio or video file AVFoundation can read into 16 kHz mono
/// Float32, the format every engine takes. [ASR]
enum AudioFileDecoder {

    enum DecodeError: LocalizedError, Equatable {
        case unreadable(String)
        case noAudioTrack

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason): return "Failed to read audio file: \(reason)"
            case .noAudioTrack: return "Failed to read audio file: it has no audio track."
            }
        }
    }

    static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }
        guard let track = tracks.first else { throw DecodeError.noAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFrame.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.unreadable("unsupported audio format") }
        reader.add(output)
        guard reader.startReading() else {
            throw DecodeError.unreadable(reader.error?.localizedDescription ?? "could not start reading")
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { samples.append(contentsOf: chunk) }
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
        }
        if reader.status == .failed {
            throw DecodeError.unreadable(reader.error?.localizedDescription ?? "decoding failed")
        }
        return samples
    }
}

// MARK: - Chunking

/// Cuts long audio into pieces an engine can take at once, each cut at the
/// quietest moment near the limit so words are not split. [ASR]
enum AudioChunker {
    /// File runs send at most this much audio per recognizer call.
    static let fileChunkSeconds: TimeInterval = 300
    /// How far back from the limit to look for a quiet cut.
    static let searchFraction = 0.15
    /// Length of the window whose loudness is compared.
    static let windowSamples = 1_600

    /// Sample ranges covering `samples` in order, none longer than
    /// `maxSeconds`. Short audio is one range.
    static func ranges(for count: Int, samples: [Float], maxSeconds: TimeInterval) -> [Range<Int>] {
        let limit = max(windowSamples * 2, Int(maxSeconds * AudioFrame.sampleRate))
        guard count > limit else { return count > 0 ? [0..<count] : [] }

        var ranges: [Range<Int>] = []
        var start = 0
        while count - start > limit {
            let hardEnd = start + limit
            let searchStart = max(start + windowSamples, hardEnd - Int(Double(limit) * searchFraction))
            let cut = quietest(in: searchStart..<hardEnd, samples: samples) ?? hardEnd
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<count)
        return ranges
    }

    /// The centre of the quietest window inside `range`.
    private static func quietest(in range: Range<Int>, samples: [Float]) -> Int? {
        guard range.count >= windowSamples else { return nil }
        var best: (index: Int, energy: Float)?
        var index = range.lowerBound
        while index + windowSamples <= range.upperBound {
            var energy: Float = 0
            for i in index..<(index + windowSamples) { energy += samples[i] * samples[i] }
            if best == nil || energy < best!.energy { best = (index, energy) }
            index += windowSamples / 2
        }
        return best.map { $0.index + windowSamples / 2 }
    }
}
