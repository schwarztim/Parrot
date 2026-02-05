import AppKit
import AVFoundation
import CoreGraphics

/// Checks and requests OS permissions required by Parrot:
/// Microphone, Input Monitoring, and Accessibility.
@Observable
final class PermissionsManager {

    // MARK: - Permission Pane

    enum PermissionPane: String {
        case microphone
        case inputMonitoring
        case accessibility
    }

    // MARK: - Observable State

    var microphoneGranted: Bool = false
    var inputMonitoringGranted: Bool = false
    var accessibilityGranted: Bool = false

    /// True when all three permissions have been granted.
    var allPermissionsGranted: Bool {
        microphoneGranted && inputMonitoringGranted && accessibilityGranted
    }

    // MARK: - Refresh

    /// Re-reads the current permission states from the OS.
    ///
    /// Call this at app launch and whenever the app returns from the background
    /// to pick up changes the user made in System Settings.
    @MainActor
    func refreshPermissions() {
        microphoneGranted = checkMicrophonePermission()
        inputMonitoringGranted = checkInputMonitoringPermission()
        accessibilityGranted = checkAccessibilityPermission()
    }

    // MARK: - Microphone

    /// Checks whether microphone access has been granted.
    func checkMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Requests microphone access. The system shows a permission dialog if
    /// the user has not yet decided.
    func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run { microphoneGranted = granted }
        return granted
    }

    // MARK: - Input Monitoring

    /// Checks whether Input Monitoring (CGEventTap) is allowed.
    ///
    /// Uses the modern preflight API on macOS 15+ and falls back to
    /// attempting a listen-only event tap on older systems.
    func checkInputMonitoringPermission() -> Bool {
        if #available(macOS 15.0, *) {
            return CGPreflightListenEventAccess()
        }
        // Fallback: attempt to create a listen-only tap and see if it succeeds.
        let testTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        let granted = testTap != nil
        return granted
    }

    /// Requests Input Monitoring access. On macOS 15+ this triggers a system
    /// prompt; on older versions it opens System Settings.
    func requestInputMonitoringAccess() {
        if #available(macOS 15.0, *) {
            CGRequestListenEventAccess()
        } else {
            openSystemPreferences(for: .inputMonitoring)
        }
    }

    // MARK: - Accessibility

    /// Checks whether Accessibility access has been granted.
    func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility access via a system dialog,
    /// then opens System Settings if they haven't already granted it.
    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = trusted
    }

    // MARK: - System Settings Deep-Link

    /// Opens the appropriate System Settings pane for a given permission.
    func openSystemPreferences(for pane: PermissionPane) {
        let urlString: String
        switch pane {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .inputMonitoring:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
