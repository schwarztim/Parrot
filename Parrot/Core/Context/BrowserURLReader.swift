import AppKit
import ApplicationServices

/// Reads the front tab's address from the frontmost browser, for website
/// activation and application context. [LLM]
///
/// Safari and Chromium browsers are asked through AppleScript (OUT's
/// `AppleScriptRunner`, so a stuck browser is cut off after a short
/// timeout); the first ask shows macOS's Automation prompt. Firefox-family
/// browsers have no such dictionary, so their web area's address is read
/// through Accessibility. Every failure returns nil.
struct BrowserURLReader {

    /// How long a browser may take to answer.
    var timeout: TimeInterval = 0.8

    static let safariBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "ai.perplexity.comet",
    ]

    static let firefoxBundleIDs: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "app.zen-browser.zen", "net.waterfox.waterfox", "io.gitlab.librewolf-community",
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return safariBundleIDs.contains(bundleID) || chromiumBundleIDs.contains(bundleID) || firefoxBundleIDs.contains(bundleID)
    }

    /// The AppleScript that returns the front tab's address, or nil for
    /// browsers read another way.
    static func script(for bundleID: String) -> String? {
        if safariBundleIDs.contains(bundleID) {
            return "tell application id \"\(bundleID)\" to return URL of front document"
        }
        if chromiumBundleIDs.contains(bundleID) {
            return "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        }
        return nil
    }

    /// True inside the test runner, which must never script the operator's
    /// browser (or trigger an Automation prompt on their Mac).
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// The front tab's address, or nil.
    func read(bundleID: String) async -> String? {
        guard !Self.isRunningTests else { return nil }
        if let source = Self.script(for: bundleID) {
            let output = try? await AppleScriptRunner(timeout: timeout).run(source)
            return Self.cleaned(output)
        }
        if Self.firefoxBundleIDs.contains(bundleID),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        {
            return Self.cleaned(Self.webAreaURL(pid: app.processIdentifier))
        }
        return nil
    }

    /// A usable address: http, https or file, trimmed; nil otherwise.
    static func cleaned(_ output: String?) -> String? {
        guard let text = output?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let scheme = URLComponents(string: text)?.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme)
        else { return nil }
        return text
    }

    // MARK: - Accessibility

    /// The `AXURL` of the first web area in the app's focused window, found
    /// breadth-first within a small budget.
    private static func webAreaURL(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }

        var queue: [AXUIElement] = [window as! AXUIElement]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let element = queue.removeFirst()
            visited += 1
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == "AXWebArea"
            {
                var url: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &url) == .success {
                    if let url = url as? URL { return url.absoluteString }
                    if let text = url as? String { return text }
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement]
            {
                queue.append(contentsOf: list)
            }
        }
        return nil
    }
}
