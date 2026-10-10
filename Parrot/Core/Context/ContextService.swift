import AppKit

/// Context sources for prompts: selection, clipboard, app, system and the
/// user's contact card. [LLM]
///
/// `start(services:)` runs once at the end of setup: it starts the
/// clipboard watcher, the modes folder watcher and, when the user opted in,
/// a first read of the contact card.
@MainActor
final class ContextService {
    /// When the user last copied something.
    let clipboard: ClipboardWatcher
    /// The frontmost browser's address.
    var browserURLs = BrowserURLReader()
    /// The Contacts "Me" card.
    let contacts = ContactCardReader()

    private var catalogCache: [String: AppCatalogEntry?] = [:]
    private lazy var computerName: String? = SystemSnapshot.computerName()

    init(clipboard: ClipboardWatcher? = nil) {
        self.clipboard = clipboard ?? ClipboardWatcher()
    }

    func start(services: AppServices) {
        clipboard.restorePending = { [weak services] in
            services?.output.clipboard.hasPendingRestore ?? false
        }
        clipboard.start()
        services.modes?.startWatching()
        if services.settings?.refinement.includeContactCard == true {
            Task { await contacts.refresh() }
        }
    }

    /// Whether the address of the frontmost browser is worth reading for
    /// this recording: some mode has site rules, or the likely mode wants
    /// application context.
    func needsBrowserURL(bundleID: String?, modes: ModeManager?, candidate: Mode?) -> Bool {
        guard BrowserURLReader.isBrowser(bundleID) else { return false }
        return (modes?.hasSiteRules ?? false) || (candidate?.contextFromActiveApplication ?? false)
    }

    /// The app catalog entry for a destination. App lookups are cached by
    /// bundle id; a known website always wins.
    func catalogEntry(bundleID: String?, url: String?) -> AppCatalogEntry? {
        if let url, let host = ModeActivation.host(of: url), let site = AppCatalog.siteEntry(forHost: host) {
            return site
        }
        guard let bundleID else { return nil }
        if let cached = catalogCache[bundleID] { return cached }
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let entry = AppCatalog.entry(bundleID: bundleID, appURL: appURL)
        catalogCache[bundleID] = entry
        return entry
    }

    /// The policy for `mode` under the current settings.
    func policy(for mode: Mode, settings: AppSettings) -> ContextPolicy {
        let refinement = settings.refinement
        let isLocal = LanguageModelCatalog.isLocal(mode.languageModelID, settings: settings)
        return ContextPolicy(
            sendsContext: refinement.destinationAwareRefinement,
            redactsUserText: !isLocal && refinement.contextLocalOnly,
            includesIdentity: refinement.includeContactCard
        )
    }

    /// Everything the prompt may use for a recording into `destination`.
    /// Each source is read only when the mode and policy will use it.
    func promptContext(for mode: Mode, destination: DictationContext, settings: AppSettings) -> PromptContext {
        let policy = policy(for: mode, settings: settings)
        guard policy.sendsContext, ModePresets.usesLanguageModel(mode.type) else { return PromptContext() }
        let wantsClipboard = mode.contextFromClipboard && !policy.redactsUserText
        let wantsApp = mode.contextFromActiveApplication
        return PromptContext.build(
            mode: mode,
            destination: destination,
            clipboardText: wantsClipboard ? clipboard.recentCopy() : nil,
            system: wantsApp ? SystemSnapshot.capture(computerName: computerName) : nil,
            user: wantsApp && policy.includesIdentity ? contacts.identity() : nil,
            catalog: wantsApp ? catalogEntry(bundleID: destination.bundleID, url: destination.browserURL) : nil,
            policy: policy
        )
    }
}
