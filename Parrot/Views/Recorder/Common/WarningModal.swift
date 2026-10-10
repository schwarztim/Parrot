import AppKit
import SwiftUI

// MARK: - State

/// One warning (ui 5.1): title, message, icon and up to two buttons.
struct WarningState: Equatable, Identifiable {
    enum ButtonRole: Equatable {
        case normal
        case destructive
        case dark
    }

    enum Layout: Equatable {
        case vertical
        case horizontal
    }

    enum Alignment: Equatable {
        case center
        case leading
    }

    struct Icon: Equatable {
        var systemImage: String
        var color: Color
    }

    var id = UUID()
    var title: String
    var message: String
    /// Nil shows no icon.
    var icon: Icon? = Icon(systemImage: "exclamationmark.triangle.fill", color: .orange)
    var primaryTitle: String
    var primaryRole: ButtonRole = .normal
    /// Nil shows only the primary button.
    var secondaryTitle: String?
    var layout: Layout = .horizontal
    var alignment: Alignment = .center
    var width: CGFloat = 340

    static func == (lhs: WarningState, rhs: WarningState) -> Bool {
        lhs.id == rhs.id
    }
}

extension WarningState {
    /// Onboarding: continuing with a permission missing.
    static func permissionsRequired(missing: [String]) -> WarningState {
        WarningState(
            title: "Permissions Required",
            message: "Parrot still needs \(missing.joined(separator: " and ")). Without it, dictation may not record, hear your key, or paste. You can grant it later from the menu bar.",
            icon: Icon(systemImage: "lock.shield", color: .orange),
            primaryTitle: "Continue Anyway",
            secondaryTitle: "Go Back",
            layout: .vertical
        )
    }

    /// The built-in mic cannot hear with the lid closed.
    static let lidClosed = WarningState(
        title: "Lid is Closed",
        message: "Your MacBook lid is closed, so the built-in microphone can't hear you. Choose another microphone.",
        icon: Icon(systemImage: "laptopcomputer.trianglebadge.exclamationmark", color: .orange),
        primaryTitle: "Choose Another",
        secondaryTitle: "Cancel"
    )
}

// MARK: - View

/// The warning card. Hosts call `onPrimary` and `onSecondary`.
struct WarningModalView: View {
    let state: WarningState
    let onPrimary: () -> Void
    var onSecondary: () -> Void = {}

    var body: some View {
        let horizontal: HorizontalAlignment = state.alignment == .center ? .center : .leading
        let textAlignment: TextAlignment = state.alignment == .center ? .center : .leading
        VStack(alignment: horizontal, spacing: 14) {
            if let icon = state.icon {
                Image(systemName: icon.systemImage)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(icon.color)
            }
            Text(state.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(textAlignment)
            Text(state.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
            buttons
                .padding(.top, 4)
        }
        .padding(22)
        .frame(width: state.width)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        )
    }

    @ViewBuilder
    private var buttons: some View {
        switch state.layout {
        case .vertical:
            VStack(spacing: 8) {
                primaryButton.frame(maxWidth: .infinity)
                if let secondary = state.secondaryTitle {
                    Button(secondary, action: onSecondary)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                }
            }
        case .horizontal:
            HStack(spacing: 10) {
                if let secondary = state.secondaryTitle {
                    Button(secondary, action: onSecondary)
                        .keyboardShortcut(.cancelAction)
                }
                primaryButton
            }
        }
    }

    private var primaryButton: some View {
        Button(action: onPrimary) {
            Text(state.primaryTitle)
                .frame(maxWidth: state.layout == .vertical ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private var tint: Color {
        switch state.primaryRole {
        case .normal: return .accentColor
        case .destructive: return .red
        case .dark: return Color(white: 0.15)
        }
    }
}

// MARK: - Presenters

extension View {
    /// Shows `warning` over this view with a dimmed backdrop. The binding
    /// clears after either button.
    func warningModal(
        _ warning: Binding<WarningState?>,
        onPrimary: @escaping (WarningState) -> Void,
        onSecondary: @escaping (WarningState) -> Void = { _ in }
    ) -> some View {
        overlay {
            if let state = warning.wrappedValue {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                    WarningModalView(
                        state: state,
                        onPrimary: {
                            warning.wrappedValue = nil
                            onPrimary(state)
                        },
                        onSecondary: {
                            warning.wrappedValue = nil
                            onSecondary(state)
                        }
                    )
                }
                .transition(.opacity)
            }
        }
    }
}

/// Shows a warning in its own centered window, for callers with no window
/// of their own (the recorder, the menu bar).
@MainActor
enum WarningModal {
    private static var panel: NSPanel?

    static func show(_ state: WarningState, onPrimary: @escaping () -> Void = {}, onSecondary: @escaping () -> Void = {}) {
        panel?.close()
        let view = WarningModalView(
            state: state,
            onPrimary: {
                close()
                onPrimary()
            },
            onSecondary: {
                close()
                onSecondary()
            }
        )
        .padding(20)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = WarningPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.close()
        panel = nil
    }
}

/// A borderless panel that still takes keys, for Return and Esc.
private final class WarningPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
