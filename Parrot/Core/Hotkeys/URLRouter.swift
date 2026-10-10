import AppKit
import Foundation

/// Where a URL handed to Parrot goes.
enum URLRoute: Equatable {
    /// A file opened with Parrot.
    case file(URL)
    /// A `parrot://agent-*` URL.
    case agent(URL)
    /// A recording action, lowercased: `toggle`, `start`, `stop`, `cancel`
    /// (or an unknown host), with its `mode` query value (a mode name).
    /// `record`, `record/start` and `record/stop` arrive as toggle, start
    /// and stop.
    case action(String, mode: String?)
    /// `parrot://mode?key=<modeKey>`: select a mode by its key.
    case selectMode(key: String)
    /// `parrot://settings`: open the settings window.
    case settings
    /// Not a file and not `parrot://`.
    case ignored

    init(_ url: URL) {
        if url.isFileURL {
            self = .file(url)
            return
        }
        guard url.scheme?.lowercased() == "parrot" else {
            self = .ignored
            return
        }
        let host = url.host()?.lowercased() ?? ""
        if host.hasPrefix("agent-") {
            self = .agent(url)
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first(where: { $0.name == name })?.value
        }
        let path = url.path().lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        switch (host, path) {
        case ("record", ""):
            self = .action("toggle", mode: value("mode"))
        case ("record", "start"):
            self = .action("start", mode: value("mode"))
        case ("record", "stop"):
            self = .action("stop", mode: nil)
        case ("mode", ""):
            if let key = value("key"), !key.isEmpty {
                self = .selectMode(key: key)
            } else {
                self = .action(host, mode: value("mode"))
            }
        case ("settings", ""):
            self = .settings
        default:
            self = .action(host, mode: value("mode"))
        }
    }
}

/// Handles every URL the app is asked to open. [TRG]
///
/// The `parrot://` scheme is for scripting (Raycast, Alfred, Stream Deck,
/// `open parrot://toggle`):
///   parrot://record               toggle dictation (Superwhisper's route)
///   parrot://record/start         start recording
///   parrot://record/stop          stop and transcribe
///   parrot://mode?key=<modeKey>   select a mode by key; does not record
///   parrot://settings             open the settings window
///   parrot://toggle[?mode=Name]   toggle dictation (optionally set a mode)
///   parrot://start[?mode=Name]    start recording
///   parrot://stop                 stop and transcribe
///   parrot://cancel               cancel without transcribing
///   parrot://agent-*              forwarded to `services.agent`
/// File URLs go to `services.transcription.openFile(_:)`.
@MainActor
final class URLRouter {

    private weak var appState: AppState?

    /// Opens the settings window. Defaults to the app delegate's window manager.
    var openSettings: @MainActor () -> Void = {
        (NSApp.delegate as? ParrotAppDelegate)?.windows?.openParrot()
    }

    init(appState: AppState) {
        self.appState = appState
    }

    func handle(_ urls: [URL]) {
        for url in urls {
            handle(url)
        }
    }

    func handle(_ url: URL) {
        guard let appState else { return }
        diagLog("[Parrot:URL] Deeplink action: \(url.absoluteString)")
        switch URLRoute(url) {
        case .file(let file):
            appState.services.transcription.openFile(file)
        case .agent(let agentURL):
            appState.services.agent.handle(url: agentURL)
        case .action(let action, let mode):
            Task { @MainActor in
                if let mode { appState.selectMode(named: mode) }
                switch action {
                case "toggle": appState.toggleDictation(trigger: .url)
                case "start": appState.startRecording(trigger: .url)
                case "stop": appState.stopRecording(trigger: .url)
                case "cancel": appState.cancelRecording()
                default: break
                }
            }
        case .selectMode(let key):
            let modes = appState.modeManager?.modes ?? appState.modes
            guard let mode = Self.mode(forKey: key, in: modes) else {
                diagLog("[Parrot:URL] Couldn't find mode (\(key)) on deeplink switch")
                return
            }
            if let modeManager = appState.modeManager {
                modeManager.selectMode(mode)
            }
            appState.currentMode = mode
        case .settings:
            openSettings()
        case .ignored:
            break
        }
    }

    /// The mode whose key is `key`: an exact match first, then ignoring case.
    nonisolated static func mode(forKey key: String, in modes: [Mode]) -> Mode? {
        modes.first { $0.key == key }
            ?? modes.first { $0.key.compare(key, options: .caseInsensitive) == .orderedSame }
    }
}
