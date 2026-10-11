import AppKit
import SwiftUI

/// The attached panel. It takes keys only when the agent composer needs
/// typing; otherwise it stays non-activating like the pill.
final class MiniAuxPanel: FloatingPanel {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
}

/// Owns the Mini recorder's windows: the pill at its snap point, the
/// attached panel above or below it, and the snap markers shown while
/// dragging. RecorderWindowController hands it each new view state. [UI]
///
/// Panels are created on first show, so headless tests never make one.
@MainActor
final class MiniRecorderController {

    let mini = MiniPanelModel()

    private let model: RecorderPanelModel
    private let settings: AppSettings

    private var pillPanel: FloatingPanel?
    private var auxPanel: MiniAuxPanel?
    private var indicators: [(point: SnapPoint, panel: NSPanel)] = []
    private var nearestIndicator: (id: Int, engaged: Bool)?

    /// Mouse location and pill origin when the current drag began.
    private var drag: (mouse: CGPoint, origin: CGPoint)?
    private var dragWatchdog: Timer?
    private var lastDragEnd = Date.distantPast

    private var hoveredControl: MiniControl?
    private var hoverTask: Task<Void, Never>?
    private var outsideClickMonitor: Any?
    private var auxCloseTask: Task<Void, Never>?
    /// The app that was frontmost before the attached panel took keys.
    private var previousApp: NSRunningApplication?

    init(model: RecorderPanelModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        mini.onHover = { [weak self] control in self?.hover(control) }
        mini.onDragChanged = { [weak self] in self?.dragChanged() }
        mini.onDragEnded = { [weak self] in self?.endDrag(snap: true) }
        mini.onPillSize = { [weak self] size in self?.fitPill(to: size) }
        mini.onAuxSize = { [weak self] size in self?.fitAux(to: size) }
    }

    // MARK: - State

    /// Shows, updates or hides the Mini recorder for `state`.
    func update(_ state: RecorderViewState) {
        let presentation = MiniRecorderLogic.presentation(for: state)
        if mini.presentation != presentation {
            if presentation.aux != mini.presentation.aux { mini.isAuxPinned = false }
            mini.presentation = presentation
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if mini.reduceMotion != reduceMotion { mini.reduceMotion = reduceMotion }

        guard presentation.showsPill else {
            hide()
            return
        }
        showPill()
        refreshAttached()
    }

    /// Hides every Mini window.
    func hide() {
        endDrag(snap: false)
        hideAux()
        pillPanel?.orderOut(nil)
    }

    // MARK: - Pill

    private func showPill() {
        let panel = pillPanel ?? makePillPanel()
        guard !panel.isVisible else { return }
        placePill(animated: false)
        panel.orderFrontRegardless()
    }

    private func makePillPanel() -> FloatingPanel {
        let hosting = NSHostingView(rootView: MiniRecorderView(model: model, mini: mini))
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        // Drags go through `dragChanged` so the pill can snap.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        pillPanel = panel
        return panel
    }

    private var snapPoints: [SnapPoint] {
        SnapGrid.points(screens: NSScreen.screens.map(\.visibleFrame))
    }

    /// Moves the pill to its saved snap point (the first point when that
    /// screen is gone).
    private func placePill(animated: Bool) {
        guard drag == nil, let panel = pillPanel,
              let point = SnapGrid.resolve(id: settings.recorder.snapPointID, in: snapPoints) else { return }
        if mini.auxPin != point.auxPin { mini.auxPin = point.auxPin }
        let size = panel.frame.size
        let frame = NSRect(origin: SnapGrid.origin(of: point, size: size), size: size)
        setFrame(panel, frame, animated: animated)
        placeAux(pillFrame: frame, screen: point.screen)
    }

    private func fitPill(to size: CGSize) {
        guard let panel = pillPanel, size.width > 0, size.height > 0, panel.frame.size != size else { return }
        panel.setContentSize(size)
        placePill(animated: false)
    }

    private func setFrame(_ panel: NSPanel, _ frame: NSRect, animated: Bool) {
        guard animated, !mini.reduceMotion, panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.2, 0.4, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - Hints

    private func hover(_ control: MiniControl?) {
        hoverTask?.cancel()
        let delay: TimeInterval
        if control == nil {
            delay = MiniRecorderLogic.hintLinger
        } else {
            // Moving between controls swaps the hint at once.
            delay = hoveredControl == nil ? MiniRecorderLogic.hintDelay : 0
        }
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            hoveredControl = control
            refreshAttached()
        }
    }

    /// Picks the hint and shows or hides the attached panel.
    private func refreshAttached() {
        let presentation = mini.presentation
        var hint: MiniHint?
        if !mini.isDragging, presentation.aux == nil {
            hint = presentation.passiveHint ?? hoveredControl.flatMap {
                MiniRecorderLogic.hint(for: $0, activity: presentation.activity, modeName: model.state.modeName)
            }
        }
        if mini.hint != hint { mini.hint = hint }

        if presentation.aux != nil || hint != nil {
            showAux()
        } else {
            hideAux()
        }
        updateOutsideClickMonitor()
        updateFocus()
    }

    // MARK: - Attached Panel

    private func showAux() {
        guard let pill = pillPanel else { return }
        let panel = auxPanel ?? makeAuxPanel()
        if panel.parent == nil {
            pill.addChildWindow(panel, ordered: .above)
        }
        if let point = SnapGrid.resolve(id: settings.recorder.snapPointID, in: snapPoints) {
            placeAux(pillFrame: pill.frame, screen: pill.screen?.visibleFrame ?? point.screen)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hideAux() {
        auxCloseTask?.cancel()
        guard let panel = auxPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makeAuxPanel() -> MiniAuxPanel {
        let hosting = NSHostingView(rootView: MiniAttachedView(model: model, mini: mini))
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        let panel = MiniAuxPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        auxPanel = panel
        return panel
    }

    private func placeAux(pillFrame: NSRect, screen: CGRect) {
        guard let panel = auxPanel else { return }
        let origin = SnapGrid.auxOrigin(pill: pillFrame, auxSize: panel.frame.size, pin: mini.auxPin, screen: screen)
        panel.setFrameOrigin(origin)
    }

    private func fitAux(to size: CGSize) {
        guard let panel = auxPanel, let pill = pillPanel, size.width > 0, size.height > 0, panel.frame.size != size else { return }
        panel.setContentSize(size)
        placeAux(pillFrame: pill.frame, screen: pill.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero)
    }

    /// A click outside Parrot's windows closes the attached panel (unless
    /// pinned) after a short delay. Global monitors only see other apps'
    /// events, so clicks on the pill itself never close it.
    private func updateOutsideClickMonitor() {
        let wants = mini.presentation.aux != nil && mini.presentation.aux != .agent
        if wants, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.outsideClick() }
            }
        } else if !wants, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func outsideClick() {
        guard !mini.isAuxPinned, let aux = mini.presentation.aux else { return }
        auxCloseTask?.cancel()
        auxCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MiniRecorderLogic.auxCloseDelay * 1_000_000_000))
            guard !Task.isCancelled, let self, mini.presentation.aux == aux else { return }
            switch aux {
            case .modeList, .result, .error:
                model.actions.close()
            case .discard:
                model.actions.resume()
            case .agent:
                break
            }
        }
    }

    /// The agent composer needs typing: the panel becomes key and the
    /// previous app gets focus back when it closes.
    private func updateFocus() {
        let needsKeys = mini.presentation.aux == .agent
        guard let panel = auxPanel else { return }
        if needsKeys, !panel.acceptsKey {
            panel.acceptsKey = true
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp = frontmost
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        } else if !needsKeys, panel.acceptsKey {
            panel.acceptsKey = false
            panel.resignKey()
            if NSApp.isActive, let previousApp {
                previousApp.activate()
            }
            previousApp = nil
        }
    }

    // MARK: - Drag and Snap

    private func dragChanged() {
        guard let panel = pillPanel else { return }
        let mouse = NSEvent.mouseLocation
        if drag == nil {
            // A short debounce after a drop so a trailing event does not
            // start a new drag.
            guard Date().timeIntervalSince(lastDragEnd) > 0.05 else { return }
            drag = (mouse, panel.frame.origin)
            mini.isDragging = true
            TooltipCenter.shared.isSuppressed = true
            refreshAttached()
            showIndicators(size: panel.frame.size)
            startDragWatchdog()
        }
        guard let drag else { return }
        panel.setFrameOrigin(CGPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y))
        highlightNearest()
    }

    /// Springs the pill to the nearest point and saves it.
    private func endDrag(snap: Bool) {
        guard drag != nil else { return }
        drag = nil
        lastDragEnd = Date()
        dragWatchdog?.invalidate()
        dragWatchdog = nil
        removeIndicators()
        if snap, let panel = pillPanel {
            let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            if let point = SnapGrid.nearest(to: center, size: panel.frame.size, in: snapPoints) {
                settings.recorder.snapPointID = point.id
            }
        }
        mini.isDragging = false
        TooltipCenter.shared.isSuppressed = false
        placePill(animated: snap)
        refreshAttached()
    }

    /// Finishes a drag whose mouse-up never arrived.
    private func startDragWatchdog() {
        dragWatchdog?.invalidate()
        dragWatchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self?.endDrag(snap: true)
                }
            }
        }
    }

    private func showIndicators(size: CGSize) {
        removeIndicators()
        for point in snapPoints {
            let hosting = NSHostingView(rootView: SnapIndicatorView(isNearest: false, isEngaged: false))
            let markerSize = hosting.fittingSize
            let center = SnapGrid.center(of: point, size: size)
            let panel = NSPanel(
                contentRect: NSRect(x: center.x - markerSize.width / 2, y: center.y - markerSize.height / 2, width: markerSize.width, height: markerSize.height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = hosting
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.orderFrontRegardless()
            indicators.append((point, panel))
        }
        // Keep the pill above its markers.
        pillPanel?.orderFrontRegardless()
        highlightNearest()
    }

    private func highlightNearest() {
        guard let pill = pillPanel else { return }
        let size = pill.frame.size
        let center = CGPoint(x: pill.frame.midX, y: pill.frame.midY)
        guard let nearest = SnapGrid.nearest(to: center, size: size, in: indicators.map(\.point)) else { return }
        let engaged = SnapGrid.isEngaged(nearest, center: center, size: size)
        if let current = nearestIndicator, current.id == nearest.id, current.engaged == engaged { return }
        nearestIndicator = (nearest.id, engaged)
        for indicator in indicators {
            let isNearest = indicator.point.id == nearest.id
            (indicator.panel.contentView as? NSHostingView<SnapIndicatorView>)?.rootView =
                SnapIndicatorView(isNearest: isNearest, isEngaged: isNearest && engaged)
        }
    }

    private func removeIndicators() {
        for indicator in indicators {
            indicator.panel.orderOut(nil)
        }
        indicators = []
        nearestIndicator = nil
    }
}
