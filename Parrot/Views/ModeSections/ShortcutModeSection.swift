import SwiftUI

/// Mode editor row for the shortcut that records in this mode. [TRG]
///
/// Stub: renders nothing yet. ModeEditSheet embeds it.
struct ShortcutModeSection: View {
    @Binding var mode: Mode

    init(mode: Binding<Mode>) {
        _mode = mode
    }

    var body: some View {
        EmptyView()
    }
}
