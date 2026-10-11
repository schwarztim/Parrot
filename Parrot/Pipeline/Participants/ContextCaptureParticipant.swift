import Foundation

/// Captures the destination, resolves the mode and renders the prompt
/// before the mic opens (LLM).
@MainActor
final class ContextCaptureParticipant: RecordingParticipant {
    private let services: AppServices

    /// Longest text a recorder chip carries (it is shown as a tooltip).
    private static let chipLimit = 200

    init(services: AppServices) {
        self.services = services
    }

    /// Runs while the target app is still frontmost:
    /// 1. Captures the frontmost app and focused field (cheap, bounded by a
    ///    0.1 s AX timeout, nothing read from secure fields). It always runs
    ///    so history and auto-activation have the bundle id.
    /// 2. Reads the browser address when a site rule or the mode needs it.
    /// 3. Picks the mode (controller override, else site, app, last
    ///    selected) and makes it active for this recording only.
    /// 4. Renders the prompt with the context the user was looking at when
    ///    they began speaking; the transcript is filled in after ASR.
    /// 5. Shows the selection and clipboard chips when they will be sent,
    ///    and warms a local model.
    func willStart(_ session: DictationSession) async {
        let settings = services.settings
        let modes = services.modes
        var context = ContextSnapshotter.capture()

        let candidate = session.mode ?? modes?.selectedMode
        if services.context.needsBrowserURL(bundleID: context.bundleID, modes: modes, candidate: candidate),
           let bundleID = context.bundleID
        {
            context.browserURL = await services.context.browserURLs.read(bundleID: bundleID)
        }
        session.context = context
        services.live.destinationLabel = (settings?.refinement.destinationAwareRefinement == true) ? context.displayLabel : nil

        if session.mode == nil {
            session.mode = modes?.resolveMode(context: context)
        }
        if let mode = session.mode {
            modes?.activate(mode)
        }
        diagLog("[Parrot:AppState] Destination: \(context.displayLabel ?? "unknown"), secure=\(context.isSecureField), mode=\(session.mode?.name ?? "-")")

        services.live.selectionChip = nil
        services.live.clipboardChip = nil
        guard let settings, let mode = session.mode else { return }

        let refines = RefinementGate.shouldRefine(mode: mode, settings: settings, forced: session.forceRefinement)
        if refines {
            let promptContext = services.context.promptContext(for: mode, destination: context, settings: settings)
            let prompt = PromptRenderer.render(mode: mode, context: promptContext)
            session.prompt = prompt
            session.promptMode = mode
            session.renderedPrompt = prompt.fullText
            services.live.selectionChip = promptContext.selectedText.map(Self.chip)
            services.live.clipboardChip = promptContext.clipboardText.map(Self.chip)

            // Costs no perceived latency: runs before the user finishes speaking.
            services.refiner.warmUp(languageModelID: mode.languageModelID, settings: settings)
        }
    }

    func didFinish(_ session: DictationSession) {
        if session.outcome == .pasted || session.outcome == .copiedOnly {
            services.context.clipboard.noteOwnWrite(since: session.startedAt)
        }
        clear()
    }

    func didCancel(_ session: DictationSession) {
        clear()
    }

    private func clear() {
        services.live.destinationLabel = nil
        services.live.selectionChip = nil
        services.live.clipboardChip = nil
        services.modes?.returnToLastSelected()
    }

    /// One line, trimmed to the chip limit.
    private static func chip(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.count > chipLimit ? String(line.prefix(chipLimit)) + "…" : line
    }
}
