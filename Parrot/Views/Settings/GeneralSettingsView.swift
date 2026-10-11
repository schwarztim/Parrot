import SwiftUI

/// Recording window style, Always show and Always close, theme, launch at
/// login, Dock icon and the menu bar click. [UI]
struct GeneralSettingsView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var recorder = appSettings.recorder
        @Bindable var general = appSettings.general

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("General")
                        .font(.title2.weight(.semibold))
                    Text("Recording window, appearance and startup")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                Form {
                    Section("Recording Window") {
                        HStack(spacing: 12) {
                            ForEach(RecordingWindowStyle.allCases) { style in
                                RecorderStyleCard(style: style, isSelected: recorder.recordingWindowStyle == style) {
                                    recorder.recordingWindowStyle = style
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        Toggle("Always show", isOn: $recorder.alwaysShowMini)
                            .disabled(recorder.recordingWindowStyle != .mini)
                        caption("Keep the mini recorder on screen while idle, so a click starts a recording. Applies to the Mini style.")

                        Toggle("Always close", isOn: $recorder.closeAfterResult)
                        caption("Close the recording window when a dictation completes, even if Parrot could not paste. Off keeps the text on screen until you close it.")
                    }

                    Section("Appearance") {
                        HStack(spacing: 12) {
                            ForEach(AppTheme.allCases) { theme in
                                ThemeCard(theme: theme, isSelected: general.theme == theme) {
                                    general.theme = theme
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section("Application") {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { appState.launchAtLogin },
                            set: { appState.setLaunchAtLogin($0) }
                        ))
                        caption("Automatically start Parrot when you log in to your Mac.")

                        Toggle("Show in Dock", isOn: $general.showInDock)
                        caption("Off keeps Parrot in the menu bar. The Dock icon then shows only while a Parrot window is open.")

                        Toggle("Start Recording on Menubar Click", isOn: $general.menubarClickRecords)
                        caption("Left click the menu bar icon to start or stop a recording. Right click opens the menu.")
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        // Show the real login item status, which can change in System Settings.
        .onAppear {
            appState.refreshLaunchAtLogin()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Cards

/// A selectable card with a preview on top and a label under it.
private struct SelectableCard<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview()
                    .frame(width: 120, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor : Color(.separatorColor), lineWidth: isSelected ? 2 : 0.5)
                    )
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Classic, Mini or None, with a live animated preview.
private struct RecorderStyleCard: View {
    let style: RecordingWindowStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        SelectableCard(title: title, isSelected: isSelected, action: action) {
            switch style {
            case .classic:
                VStack(spacing: 4) {
                    LevelBarsView(levels: [], barCount: 14, barWidth: 3, spacing: 2, height: 18)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 70, height: 6)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial))
            case .mini:
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 8))
                    LevelBarsView(levels: [], barCount: 6, barWidth: 2, spacing: 2, height: 10, color: .secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.ultraThinMaterial))
            case .none:
                Image(systemName: "eye.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .help(style.description)
    }

    private var title: String {
        switch style {
        case .classic: return "Classic"
        case .mini: return "Mini"
        case .none: return "None"
        }
    }
}

/// Auto, Light or Dark, with a small window thumbnail.
private struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        SelectableCard(title: theme.label, isSelected: isSelected, action: action) {
            switch theme {
            case .system:
                HStack(spacing: 0) {
                    thumbnail(dark: false)
                    thumbnail(dark: true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            case .light:
                thumbnail(dark: false)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            case .dark:
                thumbnail(dark: true)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func thumbnail(dark: Bool) -> some View {
        let background = dark ? Color(white: 0.16) : Color(white: 0.96)
        let line = dark ? Color(white: 0.4) : Color(white: 0.75)
        return VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 30, height: 4)
            RoundedRectangle(cornerRadius: 2).fill(line.opacity(0.7)).frame(width: 44, height: 4)
            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 20, height: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .padding(6)
    }
}

#Preview {
    GeneralSettingsView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 500, height: 600)
}
