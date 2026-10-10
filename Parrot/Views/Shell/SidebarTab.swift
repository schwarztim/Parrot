import Foundation

/// The main window's tabs, in sidebar order. Frozen.
///
/// Each tab's view file declares `static let isReady`. A workstream shows
/// its tab by setting that flag to true in the file it owns; tabs whose
/// view is still a stub stay hidden. MainWindow maps each case to its view.
enum SidebarTab: String, CaseIterable, Identifiable {
    case home
    case modes
    case vocabulary
    case history
    case models
    case sound
    case shortcuts
    case textInput
    case general
    case advanced
    case agents
    case importer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .modes: return "Modes"
        case .vocabulary: return "Vocabulary"
        case .history: return "History"
        case .models: return "Models"
        case .sound: return "Sound"
        case .shortcuts: return "Shortcuts"
        case .textInput: return "Text Input"
        case .general: return "General"
        case .advanced: return "Advanced"
        case .agents: return "Agents"
        case .importer: return "Import"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .modes: return "slider.horizontal.3"
        case .vocabulary: return "text.book.closed"
        case .history: return "clock.arrow.circlepath"
        case .models: return "cpu"
        case .sound: return "speaker.wave.2"
        case .shortcuts: return "keyboard"
        case .textInput: return "text.cursor"
        case .general: return "gearshape"
        case .advanced: return "wrench.and.screwdriver"
        case .agents: return "terminal"
        case .importer: return "square.and.arrow.down"
        }
    }

    /// Whether the sidebar shows this tab, read from the tab view's own flag.
    @MainActor
    var isAvailable: Bool {
        switch self {
        case .home: return HomeView.isReady
        case .modes: return ModesView.isReady
        case .vocabulary: return VocabularyView.isReady
        case .history: return HistoryView.isReady
        case .models: return ModelsLibraryView.isReady
        case .sound: return SoundView.isReady
        case .shortcuts: return ShortcutsSettingsView.isReady
        case .textInput: return OutputSettingsView.isReady
        case .general: return GeneralSettingsView.isReady
        case .advanced: return AdvancedSettingsView.isReady
        case .agents: return AgentsSettingsView.isReady
        case .importer: return ImportView.isReady
        }
    }

    /// The tabs the sidebar lists, in order.
    @MainActor
    static var visibleCases: [SidebarTab] {
        allCases.filter(\.isAvailable)
    }
}
