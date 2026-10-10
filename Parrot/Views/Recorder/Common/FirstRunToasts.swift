import SwiftUI

// MARK: - Catalog

/// A first-run tip card (ui 5.2): shown on one screen until the user closes
/// it or does what it suggests.
struct FirstRunToast: Equatable, Identifiable {
    enum Screen: Equatable {
        case home
        case modes
        case vocabulary
    }

    /// Persisted in `GeneralSettings.dismissedToasts` once closed.
    let id: String
    let screen: Screen
    let systemImage: String
    let title: String
    let body: String
}

/// The tips Parrot ships and which of them show. Pure. [UI]
///
/// Screens other areas own embed `FirstRunToastStack(screen:satisfied:)`
/// and pass the ids whose condition is met (for example "modes.create"
/// once a mode exists).
enum FirstRunToasts {

    static let catalog: [FirstRunToast] = [
        FirstRunToast(
            id: "home.firstDictation", screen: .home, systemImage: "mic.fill",
            title: "Dictate anywhere",
            body: "Hold your push-to-talk key in any app, speak, and let go. Parrot types it where your cursor is."
        ),
        FirstRunToast(
            id: "home.typingTest", screen: .home, systemImage: "keyboard",
            title: "How fast do you type?",
            body: "Take the typing test with the gear on the time saved tile, so Parrot can show how much time you save."
        ),
        FirstRunToast(
            id: "home.miniRecorder", screen: .home, systemImage: "capsule",
            title: "Try the mini recorder",
            body: "A small pill that stays on screen and records with one click. Pick Mini in General settings."
        ),
        FirstRunToast(
            id: "modes.create", screen: .modes, systemImage: "plus.square.on.square",
            title: "Create a new mode",
            body: "Modes change how Parrot writes: an email voice, meeting notes, or a quick message."
        ),
        FirstRunToast(
            id: "modes.activation", screen: .modes, systemImage: "app.badge",
            title: "Auto-switch with activation",
            body: "Tie a mode to apps or websites and Parrot switches to it when you dictate there."
        ),
        FirstRunToast(
            id: "modes.shortcut", screen: .modes, systemImage: "command",
            title: "Switch modes with a shortcut",
            body: "Give a mode its own key, or open the mode switcher while you record."
        ),
        FirstRunToast(
            id: "vocabulary.firstItem", screen: .vocabulary, systemImage: "text.book.closed",
            title: "Add your first word",
            body: "Names, product terms and jargon you add here are recognized more reliably."
        ),
        FirstRunToast(
            id: "vocabulary.firstReplacement", screen: .vocabulary, systemImage: "arrow.left.arrow.right",
            title: "Create your first replacement",
            body: "Swap a phrase for another every time it is dictated, like an address or a signature."
        ),
    ]

    /// The tips to show on `screen`: not closed and condition not met, in
    /// catalog order.
    static func visible(on screen: FirstRunToast.Screen, dismissed: Set<String>, satisfied: Set<String>) -> [FirstRunToast] {
        catalog.filter { $0.screen == screen && !dismissed.contains($0.id) && !satisfied.contains($0.id) }
    }

    /// The dismissed set after closing `id`.
    static func dismissing(_ id: String, from dismissed: Set<String>) -> Set<String> {
        dismissed.union([id])
    }
}

// MARK: - Views

/// The stacked tips for one screen. Closing one saves its id.
struct FirstRunToastStack: View {
    let screen: FirstRunToast.Screen
    var satisfied: Set<String> = []

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let toasts = FirstRunToasts.visible(on: screen, dismissed: appSettings.general.dismissedToasts, satisfied: satisfied)
        VStack(spacing: 8) {
            ForEach(toasts) { toast in
                FirstRunToastCard(toast: toast) {
                    appSettings.general.dismissedToasts = FirstRunToasts.dismissing(toast.id, from: appSettings.general.dismissedToasts)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: toasts)
    }
}

/// One tip: icon, title, body and a close button.
struct FirstRunToastCard: View {
    let toast: FirstRunToast
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.callout.weight(.semibold))
                Text(toast.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close tip")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
    }
}
