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
            for (delay, batch) in Self.spread(events) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        guard let session, let live, session.levelMeter != nil else { return }
                        Self.apply(batch, to: live, deviceName: session.deviceName)
                    }
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

    /// A 100 ms buffer yields two levels; they are published 50 ms apart so
    /// the bars move at 20 Hz. Other events go out at once.
    nonisolated static func spread(_ events: [LevelMeter.Event]) -> [(TimeInterval, [LevelMeter.Event])] {
        var batches: [(TimeInterval, [LevelMeter.Event])] = []
        for event in events {
            if case .levels(let levels) = event, levels.count > 1 {
                for (index, level) in levels.enumerated() {
                    batches.append((Double(index) * 0.05, [.levels([level])]))
                }
            } else {
                batches.append((0, [event]))
            }
        }
        return batches
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
