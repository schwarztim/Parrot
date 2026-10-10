import Foundation
import Observation

// MARK: - RecordingWindowStyle

enum RecordingWindowStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case mini
    case none

    var id: String { rawValue }

    var description: String {
        switch self {
        case .classic: return "Larger window with full waveform visualization"
        case .mini: return "Compact horizontal bar"
        case .none: return "No recording window shown"
        }
    }
}

// MARK: - RecorderSettings

/// The recording window. [UI]
@Observable
final class RecorderSettings {

    private enum Key {
        static let recordingWindowStyle = "parrot.recordingWindowStyle"
        static let positionX = "parrot.recorder.positionX"
        static let positionY = "parrot.recorder.positionY"
        static let closeAfterResult = "parrot.recorder.closeAfterResult"
    }

    /// Defaults to classic, the style the overlay has always opened with
    /// (before this was saved, the picker reset to classic every launch).
    var recordingWindowStyle: RecordingWindowStyle {
        didSet { store.setEncoded(recordingWindowStyle, forKey: Key.recordingWindowStyle) }
    }

    /// Saved bottom-left corner of the recorder window, in screen points.
    /// Nil means the default spot (bottom center of the screen).
    var positionX: Int? {
        didSet { save(positionX, forKey: Key.positionX) }
    }

    var positionY: Int? {
        didSet { save(positionY, forKey: Key.positionY) }
    }

    /// "Always close": close the recorder when a dictation completes even if
    /// the paste could not be confirmed. Off keeps the result on screen.
    var closeAfterResult: Bool {
        didSet { store.set(closeAfterResult, forKey: Key.closeAfterResult) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        recordingWindowStyle = store.decoded(RecordingWindowStyle.self, forKey: Key.recordingWindowStyle) ?? .classic
        positionX = store.contains(Key.positionX) ? store.int(Key.positionX, default: 0) : nil
        positionY = store.contains(Key.positionY) ? store.int(Key.positionY, default: 0) : nil
        closeAfterResult = store.bool(Key.closeAfterResult, default: false)
        self.store = store
    }

    private func save(_ value: Int?, forKey key: String) {
        if let value {
            store.set(value, forKey: key)
        } else {
            store.remove(key)
        }
    }
}
