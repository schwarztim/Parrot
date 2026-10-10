import SwiftUI

/// Mode editor rows for the voice model: model, language, translate,
/// literal punctuation, realtime, speakers. [ASR]
///
/// Stub: renders nothing yet. ModeEditSheet embeds it.
struct VoiceModeSection: View {
    @Binding var mode: Mode

    init(mode: Binding<Mode>) {
        _mode = mode
    }

    var body: some View {
        EmptyView()
    }
}
