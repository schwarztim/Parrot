import Foundation

/// Streams 16 kHz mono audio into a WAV file (PCM Int16, au F11). Samples
/// are staged in memory and written by `flush()`, which also rewrites the
/// header sizes and syncs the file, so after every flush the file on disk
/// is a complete, playable WAV: a crash loses at most the staged audio.
///
/// `consume` and `append` may run on the audio thread; `flush` and
/// `finish` on any thread. [AUD]
final class WavStreamWriter: AudioFrameSink, @unchecked Sendable {

    static let sampleRate = 16_000
    static let headerSize = 44

    let url: URL

    private let handle: FileHandle
    /// Guards `staged`.
    private let stageLock = NSLock()
    private var staged: [Float] = []
    /// Guards the file and `written`.
    private let fileLock = NSLock()
    private var written = 0
    private var isFinished = false

    /// Creates (or replaces) the file with an empty WAV.
    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        staged.reserveCapacity(Self.sampleRate * 15)
    }

    deinit {
        try? handle.close()
    }

    /// Samples written to disk so far.
    var samplesWritten: Int {
        fileLock.lock()
        defer { fileLock.unlock() }
        return written
    }

    func consume(_ frame: AudioFrame) {
        append(frame.samples)
    }

    /// Stages samples for the next flush.
    func append(_ samples: [Float]) {
        stageLock.lock()
        staged.append(contentsOf: samples)
        stageLock.unlock()
    }

    /// Appends the staged samples to the file and updates the header.
    func flush() throws {
        stageLock.lock()
        let pending = staged
        staged.removeAll(keepingCapacity: true)
        stageLock.unlock()

        fileLock.lock()
        defer { fileLock.unlock() }
        guard !isFinished else { return }
        if !pending.isEmpty {
            try handle.seekToEnd()
            try handle.write(contentsOf: Self.pcm16(pending))
            written += pending.count
        }
        let dataBytes = UInt32(clamping: written * 2)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.littleEndian(dataBytes &+ 36))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Self.littleEndian(dataBytes))
        try handle.synchronize()
    }

    /// Writes what is left and closes the file. Later calls do nothing.
    func finish() throws {
        try flush()
        fileLock.lock()
        defer { fileLock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        try handle.close()
    }

    // MARK: - Encoding

    /// The 44-byte RIFF header for `dataBytes` of 16-bit mono 16 kHz PCM.
    static func header(dataBytes: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian(dataBytes &+ 36))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian(UInt32(16)))
        data.append(littleEndian(UInt16(1))) // PCM
        data.append(littleEndian(UInt16(1))) // mono
        data.append(littleEndian(UInt32(sampleRate)))
        data.append(littleEndian(UInt32(sampleRate * 2))) // byte rate
        data.append(littleEndian(UInt16(2))) // block align
        data.append(littleEndian(UInt16(16))) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian(dataBytes))
        return data
    }

    static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
            data.append(littleEndian(Int16((clamped * Float(Int16.max)).rounded())))
        }
        return data
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
