import SwiftUI

/// Coding agent hooks: install, remove and options. [AGT]
///
/// Stub: hidden from the sidebar until `isReady` is true.
struct AgentsSettingsView: View {
    static let isReady = false

    var body: some View {
        Text(SidebarTab.agents.label)
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
