import SwiftUI

/// Mode editor rows for output: auto paste, autocapitalize, script. [OUT]
///
/// Stub: renders nothing yet. ModeEditSheet embeds it.
struct OutputModeSection: View {
    @Binding var mode: Mode

    init(mode: Binding<Mode>) {
        _mode = mode
    }

    var body: some View {
        EmptyView()
    }
}
