import Foundation

private enum LevelMeterKey: SessionKey {
    static let defaultValue: LevelMeter? = nil
}

private extension DictationSession {
    var levelMeter: LevelMeter? {
        get { self[LevelMeterKey.self] }
        set { self[LevelMeterKey.self] = newValue }
    }
}

/// Waveform levels and the silent mic warning while recording (AUD).
///
/// Publishes `live.levels` (the newest normalized levels, 20 per second of
/// audio) and `live.silentMicDevice` (the device name while the first 3 s
/// stayed silent, cleared as soon as real audio arrives). The warning stays
/// set after the mic closes so a "No Audio Detected" result can name the
/// device; the next recording clears it. Also records `session.deviceName`.
@MainActor
final class LevelMeterParticipant: RecordingParticipant {
    /// Levels kept for the recorder's bars.
    static let historySize = 48

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func willStart(_ session: DictationSession) async {
        guard session.source == .live, let recorder = services.audioRecorder else { return }
        let live = services.live
        live.levels = []
        live.silentMicDevice = nil

        let meter = LevelMeter { [weak session, weak live] events in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let session, let live, session.levelMeter != nil else { return }
                    Self.apply(events, to: live, deviceName: session.deviceName)
                }
            }
        }
        session.levelMeter = meter
        recorder.addSink(meter)
    }

    func didStart(_ session: DictationSession) {
        if let device = services.audioRecorder?.currentDevice {
            session.deviceName = device.name
        } else if session.deviceName == nil {
            session.deviceName = services.devices.activeDevice?.name
        }
    }

    func willStop(_ session: DictationSession) {
        stopMeter(session)
    }

    func didFinish(_ session: DictationSession) {
        stopMeter(session)
        if session.outcome == .pasted || session.outcome == .copiedOnly {
            services.live.silentMicDevice = nil
        }
    }

    func didCancel(_ session: DictationSession) {
        stopMeter(session)
        services.live.silentMicDevice = nil
    }

    /// Applies meter events to the live state.
    static func apply(_ events: [LevelMeter.Event], to live: LiveRecordingState, deviceName: String?) {
        for event in events {
            switch event {
            case .levels(let levels):
                live.levels = Array((live.levels + levels).suffix(historySize))
            case .silentMic(true):
                live.silentMicDevice = deviceName ?? "your microphone"
            case .silentMic(false):
                live.silentMicDevice = nil
            }
        }
    }

    private func stopMeter(_ session: DictationSession) {
        guard let meter = session.levelMeter else { return }
        session.levelMeter = nil
        services.audioRecorder?.removeSink(meter)
        services.live.levels = []
    }
}
