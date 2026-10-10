import SwiftUI

/// Advanced settings: run onboarding again and bring back closed tips. [UI]
struct AdvancedSettingsView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced")
                        .font(.title2.weight(.semibold))
                    Text("Setup and tips")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                Form {
                    Section("Setup") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Run setup again")
                                Text("Opens the welcome flow from the first page: permissions, microphone test, model and shortcut.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Start Setup") {
                                appSettings.general.onboardingProgress = 0
                                appSettings.general.hasCompletedOnboarding = false
                                (NSApp.delegate as? ParrotAppDelegate)?.windows?.showOnboardingWindow()
                            }
                        }
                    }

                    Section("Tips") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show closed tips again")
                                Text("\(appSettings.general.dismissedToasts.count) tip(s) closed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reset Tips") {
                                appSettings.general.dismissedToasts = []
                            }
                            .disabled(appSettings.general.dismissedToasts.isEmpty)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
}
