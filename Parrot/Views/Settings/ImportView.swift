import SwiftUI

/// Import from Superwhisper with a dry run and a report. [DATA]
///
/// Stub: hidden from the sidebar until `isReady` is true.
struct ImportView: View {
    static let isReady = false

    var body: some View {
        Text(SidebarTab.importer.label)
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
