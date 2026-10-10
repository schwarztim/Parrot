import AppKit
import Observation
import SwiftUI

// MARK: - Panel Model

/// What the recorder actions do. Closures, so the views stay free of
/// AppState and the controller.
struct RecorderActions {
    var stop: () -> Void = {}
    /// The Cancel button: opens the discard guard while recording.
    var requestCancel: () -> Void = {}
    var discard: () -> Void = {}
    var resume: () -> Void = {}
    /// Closes the mode list, or dismisses a lingering result or error.
    var close: () -> Void = {}
    var openModeSwitcher: () -> Void = {}
    var selectMode: (Mode) -> Void = { _ in }
    var minimize: () -> Void = {}
    var expand: () -> Void = {}
    var switchMic: () -> Void = {}
    var copyResult: () -> Void = {}
}

/// The values the recorder views read. RecorderWindowController writes it.
@MainActor
@Observable
final class RecorderPanelModel {
    var state = RecorderViewModel.reduce(RecorderInput())
    var modes: [Mode] = []
    var selectedModeID: UUID?
    var shortcuts = ShortcutLabels(dictation: nil, pushToTalk: nil, cancel: "Esc")

    @ObservationIgnored var actions = RecorderActions()
    /// Called with the content's size whenever it changes.
    @ObservationIgnored var onSizeChange: (CGSize) -> Void = { _ in }
}

// MARK: - Window Controller

/// Owns the recorder panel and keeps it in step with `LiveRecordingState`.
/// [UI]
///
/// It observes the live state, the window style and the modes, reduces them
/// with `RecorderViewModel.reduce`, and shows the panel whenever the result
/// is visible. The panel is a non-activating floating panel on every Space
/// (full-screen apps included) that never becomes key, so the app being
/// dictated into keeps focus; TRG's global keys drive Esc, arrows and digits.
/// The panel is created on first show, so headless tests never make one.
@MainActor
final class RecorderWindowController {

    /// The controller WindowManager installed at launch.
    private(set) static var current: RecorderWindowController?

    private let appState: AppState
    private let settings: AppSettings
    private let openSoundSettings: @MainActor () -> Void
    let model = RecorderPanelModel()

    private var panel: FloatingPanel?
    private var moveObserver: NSObjectProtocol?
    /// Set while Parrot moves the panel, so only user drags are saved.
    private var isPlacing = false

    private var switcherWasShown = false
    private var modeIDWhenSwitcherOpened: UUID?
    private var modeChangedName: String?
    private var modeChangedTask: Task<Void, Never>?

    private var live: LiveRecordingState { appState.services.live }

    /// Creates the controller and makes it `current`.
    @discardableResult
    static func install(
        appState: AppState,
        settings: AppSettings,
        openSoundSettings: @escaping @MainActor () -> Void = {}
    ) -> RecorderWindowController {
        let controller = RecorderWindowController(
            appState: appState,
            settings: settings,
            openSoundSettings: openSoundSettings
        )
        current = controller
        return controller
    }

    private init(
        appState: AppState,
        settings: AppSettings,
        openSoundSettings: @escaping @MainActor () -> Void
    ) {
        self.appState = appState
        self.settings = settings
        self.openSoundSettings = openSoundSettings
        model.actions = makeActions()
        model.onSizeChange = { [weak self] size in
            self?.fit(to: size)
        }
        observe()
    }

    // MARK: - Observation

    /// The tracked inputs, other than the presenter-local mode note.
    private struct Snapshot {
        var input: RecorderInput
        var modes: [Mode]
        var selectedModeID: UUID?
        var shortcuts: ShortcutLabels
    }

    private func snapshot() -> Snapshot {
        let modeManager = appState.modeManager
        let selected = modeManager?.selectedMode ?? appState.currentMode
        return Snapshot(
            input: RecorderInput(
                live: live,
                style: settings.recorder.recordingWindowStyle,
                selectedModeName: selected?.name,
                modeChangedName: nil
            ),
            modes: modeManager?.modes ?? appState.modes,
            selectedModeID: selected?.id,
            shortcuts: ShortcutLabels(hotkeys: settings.hotkeys)
        )
    }

    /// Applies the current values and applies them again whenever one changes.
    private func observe() {
        let current = withObservationTracking {
            self.snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
            }
        }
        apply(current)
    }

    /// Re-applies the current values now (after a presenter call).
    func refresh() {
        apply(snapshot())
    }

    private func apply(_ snapshot: Snapshot) {
        trackModeSwitcher(shown: snapshot.input.modeSwitcherShown, selected: snapshot.selectedModeID, modes: snapshot.modes)

        // Style None has no guard to show, so a cancel request discards.
        if snapshot.input.style == .none, snapshot.input.cancelGuardShown, snapshot.input.phase == .recording {
            appState.controller.cancel()
            return
        }

        var input = snapshot.input
        input.modeChangedName = modeChangedName
        let state = RecorderViewModel.reduce(input)

        if model.state != state { model.state = state }
        if model.modes != snapshot.modes { model.modes = snapshot.modes }
        if model.selectedModeID != snapshot.selectedModeID { model.selectedModeID = snapshot.selectedModeID }
        if model.shortcuts != snapshot.shortcuts { model.shortcuts = snapshot.shortcuts }

        if state.isVisible {
            present()
        } else {
            panel?.orderOut(nil)
        }
    }

    /// Shows the mode-changed note when the switcher closes on a different
    /// mode than it opened with.
    private func trackModeSwitcher(shown: Bool, selected: UUID?, modes: [Mode]) {
        defer { switcherWasShown = shown }
        if shown, !switcherWasShown {
            modeIDWhenSwitcherOpened = selected
            return
        }
        guard !shown, switcherWasShown, let opened = modeIDWhenSwitcherOpened, opened != selected else { return }
        modeIDWhenSwitcherOpened = nil
        guard let name = modes.first(where: { $0.id == selected })?.name else { return }
        flashModeChanged(name)
    }

    private func flashModeChanged(_ name: String) {
        modeChangedName = name
        modeChangedTask?.cancel()
        modeChangedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RecorderViewModel.modeChangedDuration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.modeChangedName = nil
            self.refresh()
        }
    }

    // MARK: - Actions

    private func makeActions() -> RecorderActions {
        RecorderActions(
            stop: { [weak self] in
                guard let self else { return }
                appState.controller.stop(trigger: live.trigger ?? .menu)
            },
            requestCancel: { [weak self] in
                guard let self else { return }
                switch appState.controller.phase {
                case .recording:
                    live.cancelGuardShown = true
                case .starting:
                    appState.controller.cancel()
                case .idle, .stopping, .processing:
                    break
                }
            },
            discard: { [weak self] in
                self?.appState.controller.cancel()
            },
            resume: { [weak self] in
                self?.live.cancelGuardShown = false
            },
            close: { [weak self] in
                guard let self else { return }
                if live.modeSwitcherShown {
                    live.modeSwitcherShown = false
                } else {
                    live.resultText = nil
                    live.errorText = nil
                }
            },
            openModeSwitcher: { [weak self] in
                self?.live.modeSwitcherShown = true
            },
            selectMode: { [weak self] mode in
                guard let self else { return }
                if let modeManager = appState.modeManager {
                    modeManager.selectMode(mode)
                    appState.currentMode = modeManager.selectedMode
                } else {
                    appState.currentMode = mode
                }
                live.modeSwitcherShown = false
            },
            minimize: { [weak self] in
                self?.settings.recorder.recordingWindowStyle = .mini
            },
            expand: { [weak self] in
                self?.settings.recorder.recordingWindowStyle = .classic
            },
            switchMic: { [weak self] in
                guard let self else { return }
                live.errorText = nil
                openSoundSettings()
            },
            copyResult: { [weak self] in
                guard let text = self?.live.resultText, !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        )
    }

    // MARK: - Panel

    private func present() {
        let panel = self.panel ?? makePanel()
        guard !panel.isVisible else { return }
        place(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> FloatingPanel {
        let hosting = NSHostingView(rootView: RecorderRootView(model: model))
        // The panel is sized by `fit(to:)` from the content's reported size,
        // not by the hosting view's constraints.
        hosting.sizingOptions = []
        let size = hosting.fittingSize

        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        // The content draws its own shadow; a window shadow would go stale
        // as the panel resizes.
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panelDidMove()
            }
        }
        self.panel = panel
        return panel
    }

    /// Puts the panel at the saved position, or bottom center of the screen
    /// under the pointer.
    private func place(_ panel: NSPanel) {
        let saved: CGPoint? = {
            guard let x = settings.recorder.positionX, let y = settings.recorder.positionY else { return nil }
            return CGPoint(x: x, y: y)
        }()
        let screens = NSScreen.screens
        let pointer = NSEvent.mouseLocation
        let fallback = screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? screens.first
        guard let fallback else { return }
        let origin = RecorderViewModel.origin(
            saved: saved,
            size: panel.frame.size,
            screens: screens.map(\.visibleFrame),
            fallback: fallback.visibleFrame
        )
        move(panel, to: NSRect(origin: origin, size: panel.frame.size))
    }

    /// Resizes the panel to the content, keeping its bottom edge (so it grows
    /// upward) and keeping it on its screen.
    private func fit(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0, panel.frame.size != size else { return }
        var frame = NSRect(origin: panel.frame.origin, size: size)
        if let screen = panel.screen?.visibleFrame {
            frame.origin = RecorderViewModel.clamp(origin: frame.origin, size: size, into: screen)
        }
        move(panel, to: frame)
    }

    private func move(_ panel: NSPanel, to frame: NSRect) {
        isPlacing = true
        panel.setFrame(frame, display: true)
        isPlacing = false
    }

    private func panelDidMove() {
        guard !isPlacing, let panel, panel.isVisible else { return }
        let origin = panel.frame.origin
        settings.recorder.positionX = Int(origin.x.rounded())
        settings.recorder.positionY = Int(origin.y.rounded())
    }
}
