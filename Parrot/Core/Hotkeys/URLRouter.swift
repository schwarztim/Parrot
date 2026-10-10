import Foundation

/// Where a URL handed to Parrot goes.
enum URLRoute: Equatable {
    /// A file opened with Parrot.
    case file(URL)
    /// A `parrot://agent-*` URL.
    case agent(URL)
    /// Any other `parrot://` host, lowercased, with its `mode` query value.
    case action(String, mode: String?)
    /// Not a file and not `parrot://`.
    case ignored

    init(_ url: URL) {
        if url.isFileURL {
            self = .file(url)
            return
        }
        guard url.scheme == "parrot" else {
            self = .ignored
            return
        }
        let action = url.host()?.lowercased() ?? ""
        if action.hasPrefix("agent-") {
            self = .agent(url)
            return
        }
        let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "mode" })?.value
        self = .action(action, mode: mode)
    }
}

/// Handles every URL the app is asked to open. [TRG]
///
/// The `parrot://` scheme is for scripting (Raycast, Alfred, Stream Deck,
/// `open parrot://toggle`):
///   parrot://toggle[?mode=Name]   toggle dictation (optionally set a mode)
///   parrot://start[?mode=Name]    start recording
///   parrot://stop                 stop and transcribe
///   parrot://cancel               cancel without transcribing
///   parrot://agent-*              forwarded to `services.agent`
/// File URLs go to `services.transcription.openFile(_:)`.
@MainActor
final class URLRouter {

    private weak var appState: AppState?

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
        case .ignored:
            break
        }
    }
}
