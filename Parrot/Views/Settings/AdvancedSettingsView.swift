import SwiftUI

/// Advanced settings. [UI]
///
/// Stub: hidden from the sidebar until `isReady` is true.
struct AdvancedSettingsView: View {
    static let isReady = false

    var body: some View {
        Text(SidebarTab.advanced.label)
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
