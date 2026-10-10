import SwiftUI

/// Text input settings: paste, clipboard and keystrokes. [OUT]
///
/// Stub: hidden from the sidebar until `isReady` is true.
struct OutputSettingsView: View {
    static let isReady = false

    var body: some View {
        Text(SidebarTab.textInput.label)
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
