import AppKit

/// "Transcribe File...": pick an audio or video file and transcribe it
/// with the selected mode. The text goes to the clipboard and history.
/// Disabled while a dictation is running. [ASR]
@MainActor
struct FileMenuSection: MenuSection {
    let context: MenuContext

    init(context: MenuContext) {
        self.context = context
    }

    func items() -> [NSMenuItem] {
        let controller = context.appState.controller
        let item = ActionMenuItem(title: "Transcribe File...", systemImage: "doc.text.magnifyingglass") {
            FileTranscriber.forController(controller).pickAndTranscribe()
        }
        item.toolTip = "Opens a file picker for audio or video transcription"
        item.isEnabled = controller.phase == .idle
        return [item]
    }
}
