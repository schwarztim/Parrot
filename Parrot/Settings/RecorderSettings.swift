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
    }

    /// Defaults to classic, the style the overlay has always opened with
    /// (before this was saved, the picker reset to classic every launch).
    var recordingWindowStyle: RecordingWindowStyle {
        didSet { store.setEncoded(recordingWindowStyle, forKey: Key.recordingWindowStyle) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        recordingWindowStyle = store.decoded(RecordingWindowStyle.self, forKey: Key.recordingWindowStyle) ?? .classic
        self.store = store
    }
}
