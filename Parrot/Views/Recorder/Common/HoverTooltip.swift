import AppKit
import SwiftUI

// MARK: - Logic

/// Where a tooltip sits next to its trigger.
enum TooltipPlacement: Equatable {
    case above
    case leading
    case trailing
}

/// Pure tooltip timing and placement (ui 5.5). [UI]
enum TooltipLogic {

    /// Seconds of hovering before a cold tooltip shows.
    static let showDelay: TimeInterval = 0.5
    /// After a tooltip hides, others show at once for this long ("warm").
    static let warmCooldown: TimeInterval = 1.0
    static let gap: CGFloat = 6

    /// The delay before showing: none while warm (one is showing, or one hid
    /// less than `warmCooldown` ago), otherwise `showDelay`.
    static func delay(now: Date, isShowing: Bool, lastHiddenAt: Date?) -> TimeInterval {
        if isShowing { return 0 }
        if let lastHiddenAt, now.timeIntervalSince(lastHiddenAt) < warmCooldown { return 0 }
        return showDelay
    }

    /// Bottom-left corner of a tooltip of `size` for a trigger at `anchor`
    /// (screen coordinates). Flips to the other side when it would leave
    /// `screen`, then keeps it inside.
    static func origin(anchor: CGRect, size: CGSize, placement: TooltipPlacement, screen: CGRect) -> CGPoint {
        var origin: CGPoint
        switch placement {
        case .above:
            origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
            if origin.y + size.height > screen.maxY {
                origin.y = anchor.minY - gap - size.height
            }
        case .leading:
            origin = CGPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
            if origin.x < screen.minX {
                origin.x = anchor.maxX + gap
            }
        case .trailing:
            origin = CGPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
            if origin.x + size.width > screen.maxX {
                origin.x = anchor.minX - gap - size.width
            }
        }
        return RecorderViewModel.clamp(origin: origin, size: size, into: screen)
    }
}

// MARK: - Center

/// Shows one custom tooltip at a time in its own panel. Only the owner that
/// showed it can hide it; nothing shows while suppressed (a drag) or while
/// a mouse button is down.
@MainActor
final class TooltipCenter {
    static let shared = TooltipCenter()

    /// Set during drags.
    var isSuppressed = false {
        didSet { if isSuppressed { hideNow() } }
    }

    private var panel: NSPanel?
    private var owner: UUID?
    private var lastHiddenAt: Date?
    private var pending: Task<Void, Never>?

    func request(owner: UUID, title: String, subtitle: String?, placement: TooltipPlacement, anchor: @escaping () -> CGRect?) {
        pending?.cancel()
        let delay = TooltipLogic.delay(now: Date(), isShowing: self.owner != nil, lastHiddenAt: lastHiddenAt)
        pending = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, !isSuppressed, NSEvent.pressedMouseButtons == 0,
                  let rect = anchor() else { return }
            show(owner: owner, title: title, subtitle: subtitle, placement: placement, anchor: rect)
        }
    }

    func release(owner: UUID) {
        pending?.cancel()
        guard self.owner == owner else { return }
        hideNow()
    }

    private func show(owner: UUID, title: String, subtitle: String?, placement: TooltipPlacement, anchor: CGRect) {
        let hosting = NSHostingView(rootView: TooltipCard(title: title, subtitle: subtitle))
        let size = hosting.fittingSize
        let panel = self.panel ?? makePanel()
        panel.contentView = hosting
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let origin = TooltipLogic.origin(anchor: anchor, size: size, placement: placement, screen: screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        self.owner = owner
    }

    private func hideNow() {
        pending?.cancel()
        guard owner != nil else { return }
        panel?.orderOut(nil)
        owner = nil
        lastHiddenAt = Date()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }
}

/// The tooltip card: a title and an optional subtitle, line-limited.
private struct TooltipCard: View {
    let title: String
    let subtitle: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .padding(8)
        .scaleEffect(shown || reduceMotion ? 1 : 0.92)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8)) { shown = true }
        }
    }
}

// MARK: - Modifier

/// Finds the trigger's frame on screen.
private struct TooltipAnchor: NSViewRepresentable {
    let box: TooltipAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

private final class TooltipAnchorBox {
    weak var view: NSView?

    @MainActor
    var screenRect: CGRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let title: String
    let subtitle: String?
    let placement: TooltipPlacement

    @State private var owner = UUID()
    @State private var box = TooltipAnchorBox()

    func body(content: Content) -> some View {
        content
            .background(TooltipAnchor(box: box))
            .onHover { inside in
                if inside {
                    let box = self.box
                    TooltipCenter.shared.request(owner: owner, title: title, subtitle: subtitle, placement: placement) {
                        box.screenRect
                    }
                } else {
                    TooltipCenter.shared.release(owner: owner)
                }
            }
            .onDisappear {
                TooltipCenter.shared.release(owner: owner)
            }
    }
}

extension View {
    /// A custom hover tooltip (ui 5.5) with a title and optional subtitle.
    func hoverTooltip(_ title: String, subtitle: String? = nil, placement: TooltipPlacement = .above) -> some View {
        modifier(HoverTooltipModifier(title: title, subtitle: subtitle, placement: placement))
    }
}
