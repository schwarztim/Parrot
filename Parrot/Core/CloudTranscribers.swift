import Foundation

// MARK: - TranscriptionProvider

/// A speech-to-text backend that turns 16kHz mono Float32 samples into text.
/// The on-device Parakeet engine and the cloud transcribers both conform.
protocol TranscriptionProvider {
    func transcribe(_ samples: [Float]) async throws -> String
}

extension TranscriptionEngine: TranscriptionProvider {}

// MARK: - TranscriptionProviderChoice

/// The speech-to-text backend selected in settings.
enum TranscriptionProviderChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case parakeet
    case openAI
    case azureWhisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet V3 (on-device)"
        case .openAI: return "OpenAI (cloud)"
        case .azureWhisper: return "Azure Whisper (cloud)"
        }
    }
}

// MARK: - OpenAITranscriber

/// Cloud transcription via POST https://api.openai.com/v1/audio/transcriptions
/// (multipart/form-data, Authorization: Bearer). Response: {"text": "..."}.
struct OpenAITranscriber: TranscriptionProvider {

    let apiKey: String
    /// "whisper-1", "gpt-4o-transcribe", or "gpt-4o-mini-transcribe".
    let model: String
    var timeoutInterval: TimeInterval = 60
    /// ISO 639-1 code of the spoken language; nil lets the service detect it.
    var language: String?

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw CloudTranscriberError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // OpenAI requires the model as a form field.
        var fields = ["model": model]
        if let language { fields["language"] = language }
        return try await CloudTranscriberHTTP.send(
            request: request,
            samples: samples,
            extraFields: fields,
            timeoutInterval: timeoutInterval
        )
    }
}

// MARK: - AzureWhisperTranscriber

/// Cloud transcription via POST {endpoint}/openai/deployments/{deployment}
/// /audio/transcriptions?api-version={ver} (multipart/form-data, api-key
/// header). The deployment is in the URL; no model form field is needed.
struct AzureWhisperTranscriber: TranscriptionProvider {

    let endpoint: String
    let apiKey: String
    let deployment: String
    let apiVersion: String
    var timeoutInterval: TimeInterval = 60
    /// ISO 639-1 code of the spoken language; nil lets the service detect it.
    var language: String?

    func transcribe(_ samples: [Float]) async throws -> String {
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/openai/deployments/\(deployment)/audio/transcriptions?api-version=\(apiVersion)"
        guard let url = URL(string: urlString) else {
            throw CloudTranscriberError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        return try await CloudTranscriberHTTP.send(
            request: request,
            samples: samples,
            extraFields: language.map { ["language": $0] } ?? [:],
            timeoutInterval: timeoutInterval
        )
    }
}

// MARK: - Cloud Providers From Settings

/// Builds the configured cloud transcriber for a provider choice.
enum CloudTranscription {
    /// The transcriber for `choice`, or nil when its settings are
    /// incomplete (or the choice is on-device).
    @MainActor
    static func provider(
        for choice: TranscriptionProviderChoice,
        settings: AppSettings?,
        language: String? = nil
    ) -> TranscriptionProvider? {
        guard let settings else { return nil }
        let transcription = settings.transcription
        let refinement = settings.refinement
        switch choice {
        case .parakeet:
            return nil
        case .openAI:
            let apiKey = settings.credentials.key(for: .openAI)
            guard !apiKey.isEmpty, !transcription.openAITranscriptionModel.isEmpty else { return nil }
            return OpenAITranscriber(
                apiKey: apiKey, model: transcription.openAITranscriptionModel, language: language
            )
        case .azureWhisper:
            let apiKey = settings.credentials.key(for: .azureOpenAI)
            guard !refinement.azureOpenAIEndpoint.isEmpty,
                  !apiKey.isEmpty,
                  !transcription.azureWhisperDeployment.isEmpty
            else { return nil }
            return AzureWhisperTranscriber(
                endpoint: refinement.azureOpenAIEndpoint,
                apiKey: apiKey,
                deployment: transcription.azureWhisperDeployment,
                apiVersion: refinement.azureOpenAIAPIVersion,
                language: language
            )
        }
    }
}

/// A cloud transcriber in the router's engine shape. Nothing to download
/// or load; each dictation builds a fresh one from settings.
final class CloudBatchEngine: BatchTranscriptionEngine, @unchecked Sendable {
    let provider: TranscriptionProvider

    init(provider: TranscriptionProvider) {
        self.provider = provider
    }

    func isDownloaded() async -> Bool { true }
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func load() async throws {}
    func unload() async {}

    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptOutput {
        let text = try await provider(language: options.language).transcribe(samples)
        return TranscriptOutput(text: text, language: options.language)
    }

    /// The provider told the mode's language, when it accepts one.
    private func provider(language: String?) -> TranscriptionProvider {
        guard let language else { return provider }
        switch provider {
        case var openAI as OpenAITranscriber:
            openAI.language = language
            return openAI
        case var azure as AzureWhisperTranscriber:
            azure.language = language
            return azure
        default:
            return provider
        }
    }
}

// MARK: - Shared HTTP / Multipart

private enum CloudTranscriberHTTP {

    /// Encodes samples as WAV, uploads them multipart, and decodes {"text"}.
    static func send(
        request baseRequest: URLRequest,
        samples: [Float],
        extraFields: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> String {
        var request = baseRequest
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval

        let boundary = "parrot-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let wavData = WAVEncoder.encode(samples: samples)
        var body = Data()
        for (name, value) in extraFields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriberError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw CloudTranscriberError.providerError(
                statusCode: httpResponse.statusCode,
                message: decodeErrorMessage(from: data)
            )
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }

    /// Both OpenAI and Azure use {"error": {"message": ...}}.
    private static func decodeErrorMessage(from data: Data) -> String {
        if let wrapped = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return wrapped.error.message
        }
        return String(data: data, encoding: .utf8) ?? "<unreadable>"
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody
        struct ErrorBody: Decodable {
            let message: String
        }
    }
}

// MARK: - WAV Encoding

/// Encodes 16kHz mono Float32 samples as a 16-bit PCM WAV file in memory.
enum WAVEncoder {

    static let sampleRate: UInt32 = 16_000

    static func encode(samples: [Float]) -> Data {
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2)

        var data = Data(capacity: 44 + samples.count * 2)
        data.append("RIFF".data(using: .ascii)!)
        appendLE(&data, UInt32(36 + dataSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        appendLE(&data, UInt32(16))          // fmt chunk size
        appendLE(&data, UInt16(1))           // PCM
        appendLE(&data, channels)
        appendLE(&data, sampleRate)
        appendLE(&data, byteRate)
        appendLE(&data, blockAlign)
        appendLE(&data, bitsPerSample)
        data.append("data".data(using: .ascii)!)
        appendLE(&data, dataSize)

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, sample) in samples.enumerated() {
            let clamped = max(-1.0, min(1.0, sample))
            pcm[i] = Int16(clamped * Float(Int16.max))
        }
        pcm.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: buffer.count * 2
            ))
        }
        return data
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

// MARK: - Errors

enum CloudTranscriberError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case providerError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Invalid transcription endpoint URL."
        case .invalidResponse:
            return "Received an invalid response from the transcription server."
        case .providerError(let statusCode, let message):
            return "HTTP \(statusCode): \(message)"
        }
    }
}
