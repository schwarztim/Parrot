import SwiftUI

/// Mode editor rows for audio: playback while recording, system audio.
/// [AUD]
///
/// Stub: renders nothing yet. ModeEditSheet embeds it.
struct AudioModeSection: View {
    @Binding var mode: Mode

    init(mode: Binding<Mode>) {
        _mode = mode
    }

    var body: some View {
        EmptyView()
    }
}
