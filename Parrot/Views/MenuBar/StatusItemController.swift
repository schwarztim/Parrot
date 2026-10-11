import AppKit
import Observation

// MARK: - Icon State

/// What the menu bar icon shows (oh F22).
enum StatusIconState: Equatable {
    /// The local model is downloading.
    case loading
    case ready
    case recording
    /// Stopping or processing.
    case working
    /// A dictation just delivered; shown briefly, then back to ready.
    case complete

    /// Seconds Complete shows before the icon returns to Ready.
    static let completeDuration: TimeInterval = 1.0

    /// The state for the controller phase and app status. `isCompleting`
    /// is true for a moment after a dictation delivered.
    static func resolve(phase: DictationPhase, status: AppStatus, isCompleting: Bool) -> StatusIconState {
        switch phase {
        case .starting, .recording:
            return .recording
        case .stopping, .processing:
            return .working
        case .idle:
            break
        }
        if case .downloading = status { return .loading }
        return isCompleting ? .complete : .ready
    }

    /// Recording and Working animate through frames.
    var isAnimated: Bool {
        self == .recording || self == .working
    }
}

// MARK: - Icon Frames

/// The drawn menu bar icon frames. Recording shows five bars that sway and
/// rise with the mic level; Working shows three dots in a running pulse.
/// Frames advance every 25 ms.
enum StatusIconFrames {

    static let interval: TimeInterval = 0.025
    /// Frames in one animation cycle (one second).
    static let cycle = 40

    /// Heights (0...1) of the five recording bars at `frame`, lifted by the
    /// mic `level` (0...1).
    static func recordingBars(frame: Int, level: Float) -> [Double] {
        let phase = Double(frame % cycle) / Double(cycle) * 2 * .pi
        let lift = Double(max(0, min(1, level.isFinite ? level : 0)))
        return (0..<5).map { index in
            let sway = (sin(phase + Double(index) * 1.1) + 1) / 2
            return min(1, 0.25 + 0.35 * sway + 0.4 * lift)
        }
    }

    /// Opacities (0...1) of the three working dots at `frame`: one bright
    /// dot runs left to right.
    static func workingDots(frame: Int) -> [Double] {
        let position = Double(frame % cycle) / Double(cycle) * 3
        return (0..<3).map { index in
            let distance = abs(position - Double(index) - 0.5)
            let wrapped = min(distance, 3 - distance)
            return max(0.3, 1 - wrapped * 0.7)
        }
    }

    /// The template image for `state` at `frame`.
    static func image(
        for state: StatusIconState,
        frame: Int,
        level: Float,
        needsAttention: Bool
    ) -> NSImage? {
        let image: NSImage?
        switch state {
        case .recording:
            image = drawBars(recordingBars(frame: frame, level: level))
        case .working:
            image = drawDots(workingDots(frame: frame))
        case .loading:
            image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Parrot: loading")
        case .complete:
            image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Parrot: done")
        case .ready:
            image = NSImage(
                systemSymbolName: needsAttention ? "mic.badge.xmark" : "mic.fill",
                accessibilityDescription: needsAttention ? "Parrot: permission needed" : "Parrot"
            )
        }
        image?.isTemplate = true
        return image
    }

    private static let size = NSSize(width: 18, height: 18)

    private static func drawBars(_ heights: [Double]) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 2.2
            let gap: CGFloat = 1.3
            let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            var x = rect.midX - total / 2
            NSColor.black.setFill()
            for height in heights {
                let barHeight = max(barWidth, rect.height * 0.8 * CGFloat(height))
                let bar = NSRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
        image.accessibilityDescription = "Parrot: recording"
        return image
    }

    private static func drawDots(_ opacities: [Double]) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let diameter: CGFloat = 3.4
            let gap: CGFloat = 2.2
            let total = CGFloat(opacities.count) * diameter + CGFloat(opacities.count - 1) * gap
            var x = rect.midX - total / 2
            for opacity in opacities {
                NSColor.black.withAlphaComponent(CGFloat(opacity)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: rect.midY - diameter / 2, width: diameter, height: diameter)).fill()
                x += diameter + gap
            }
            return true
        }
        image.accessibilityDescription = "Parrot: working"
        return image
    }
}

// MARK: - Status Item

/// The menu bar icon and its menu. [UI]
///
/// The icon follows the dictation (loading, ready, recording, working,
/// complete), animating Recording and Working with 25 ms frames. Clicking
/// opens a menu that MenuLayout rebuilds each time it opens; with "Start
/// Recording on Menubar Click" on, a left click starts or stops recording
/// and a right click (or Control-click) opens the menu. The ready icon
/// flags missing permissions once onboarding is done.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let context: MenuContext
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private var iconState: StatusIconState = .ready
    private var needsAttention = false
    private var frame = 0
    private var animationTimer: Timer?

    private var isCompleting = false
    private var completeTask: Task<Void, Never>?
    private var lastSuccessCount: Int

    private var clickRecords: Bool?

    init(context: MenuContext) {
        self.context = context
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.lastSuccessCount = context.settings.general.successfulDictationCount
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        observe()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuLayout.populate(menu, context: context)
    }

    // MARK: - Observation

    private struct Snapshot {
        var phase: DictationPhase
        var status: AppStatus
        var successCount: Int
        var needsAttention: Bool
        var clickRecords: Bool
    }

    private func snapshot() -> Snapshot {
        let appState = context.appState
        // Flag missing permissions in the glyph, but only once onboarding is
        // done (during onboarding the wizard owns permissions).
        let attention = context.settings.general.hasCompletedOnboarding && !appState.permissionWarnings.isEmpty
        return Snapshot(
            phase: appState.services.live.phase,
            status: appState.currentStatus,
            successCount: context.settings.general.successfulDictationCount,
            needsAttention: attention,
            clickRecords: context.settings.general.menubarClickRecords
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

    private func apply(_ snapshot: Snapshot) {
        configureClicks(recordOnClick: snapshot.clickRecords)

        if snapshot.successCount > lastSuccessCount {
            startCompleting()
        }
        lastSuccessCount = snapshot.successCount
        if snapshot.phase != .idle {
            stopCompleting()
        }

        needsAttention = snapshot.needsAttention
        let state = StatusIconState.resolve(phase: snapshot.phase, status: snapshot.status, isCompleting: isCompleting)
        setIconState(state)
    }

    // MARK: - Icon

    private func setIconState(_ state: StatusIconState) {
        let changed = state != iconState || statusItem.button?.image == nil
        iconState = state
        if changed {
            // Each state runs its own frames; a change always restarts them.
            animationTimer?.invalidate()
            animationTimer = nil
            frame = 0
            if state.isAnimated {
                let timer = Timer(timeInterval: StatusIconFrames.interval, repeats: true) { [weak self] _ in
                    // Scheduled on the main run loop, so it fires on main.
                    MainActor.assumeIsolated {
                        self?.advanceFrame()
                    }
                }
                // Common modes keep it running while the menu is open.
                RunLoop.main.add(timer, forMode: .common)
                animationTimer = timer
            }
        }
        drawIcon()
    }

    private func advanceFrame() {
        frame = (frame + 1) % StatusIconFrames.cycle
        drawIcon()
    }

    private func drawIcon() {
        let level = context.appState.services.live.levels.last ?? 0
        statusItem.button?.image = StatusIconFrames.image(
            for: iconState,
            frame: frame,
            level: level,
            needsAttention: needsAttention
        )
    }

    private func startCompleting() {
        isCompleting = true
        completeTask?.cancel()
        completeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(StatusIconState.completeDuration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.isCompleting = false
            self.apply(self.snapshot())
        }
    }

    private func stopCompleting() {
        isCompleting = false
        completeTask?.cancel()
        completeTask = nil
    }

    // MARK: - Clicks

    /// With record-on-click, the button handles left and right mouse up
    /// itself and the menu opens only on demand. Without it, the attached
    /// menu opens on any click.
    private func configureClicks(recordOnClick: Bool) {
        guard recordOnClick != clickRecords else { return }
        clickRecords = recordOnClick
        if recordOnClick {
            statusItem.menu = nil
            statusItem.button?.target = self
            statusItem.button?.action = #selector(buttonClicked(_:))
            statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        } else {
            statusItem.button?.target = nil
            statusItem.button?.action = nil
            statusItem.menu = menu
        }
    }

    @objc private func buttonClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            // Attach the menu just for this click; performClick opens it and
            // returns when it closes.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            context.appState.toggleDictation(trigger: .menu)
        }
    }
}
