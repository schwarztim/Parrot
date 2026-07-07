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
    /// **Important:** On macOS 15+, `CGPreflightListenEventAccess()` is
    /// unreliable — it can return `true` even when the app is NOT in the
    /// TCC Input Monitoring list. The CGEventTap will be created
    /// successfully but macOS silently drops events ("deaf tap").
    ///
    /// To work around this, we always call `CGRequestListenEventAccess()`
    /// on first launch (via `ensureInputMonitoringAccess()`) and rely on
    /// the HotkeyManager self-test to detect deaf taps at runtime.
    func checkInputMonitoringPermission() -> Bool {
        if #available(macOS 15.0, *) {
            // Note: This API is unreliable on macOS 15+. It may return
            // true even when the app lacks Input Monitoring permission.
            // We keep calling it for UI status but do NOT skip the
            // access request based on its result.
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
    @discardableResult
    func requestInputMonitoringAccess() -> Bool {
        if #available(macOS 15.0, *) {
            return CGRequestListenEventAccess()
        } else {
            openSystemPreferences(for: .inputMonitoring)
            return false
        }
    }

    /// Ensures Input Monitoring permission is granted. On macOS 15+, this
    /// **always** calls `CGRequestListenEventAccess()` because the preflight
    /// API is unreliable. If the app already has the permission, the call
    /// returns `true` without showing a dialog.
    func ensureInputMonitoringAccess() {
        if #available(macOS 15.0, *) {
            let result = CGRequestListenEventAccess()
            diagLog("[Parrot:Permissions] CGRequestListenEventAccess() = \(result)")
            if !result {
                diagLog("[Parrot:Permissions] Input Monitoring NOT granted — opening System Settings")
                openSystemPreferences(for: .inputMonitoring)
            }
            inputMonitoringGranted = result
        } else {
            let ok = checkInputMonitoringPermission()
            if !ok {
                openSystemPreferences(for: .inputMonitoring)
            }
            inputMonitoringGranted = ok
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
