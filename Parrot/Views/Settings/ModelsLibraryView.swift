import SwiftUI

/// The two halves of the Models tab.
enum ModelsLibrarySegment: String, CaseIterable, Identifiable {
    case voice
    case language

    var id: String { rawValue }

    var label: String {
        switch self {
        case .voice: return "Voice"
        case .language: return "Language"
        }
    }
}

/// The Models tab: Voice (VoiceModelsView, ASR) and Language
/// (LanguageModelsView, LLM) segments. Frozen. The selected segment lives in
/// `appState.navigation.modelsSegment` so other views can open either one.
struct ModelsLibraryView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var navigation = appState.navigation

        VStack(spacing: 0) {
            Picker("Models", selection: $navigation.modelsSegment) {
                ForEach(ModelsLibrarySegment.allCases) { segment in
                    Text(segment.label).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .padding(.top, 12)
            .padding(.bottom, 4)

            switch navigation.modelsSegment {
            case .voice:
                VoiceModelsView()
            case .language:
                LanguageModelsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    ModelsLibraryView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 500, height: 600)
}
