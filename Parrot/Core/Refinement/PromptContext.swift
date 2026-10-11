import Foundation

/// The APPLICATION CONTEXT section: where the text is going. [LLM]
struct ApplicationSnapshot: Equatable, Sendable {
    var appName: String?
    var url: String?
    var category: String?
    var appDescription: String?
    var inputFormat: String?
    var fieldRole: String?
    var fieldLabel: String?
    var isEmptyField = false
    var textBeforeCursor: String?
    var textAfterCursor: String?

    var hasContent: Bool {
        [appName, url, category, appDescription, inputFormat, fieldRole, fieldLabel, textBeforeCursor, textAfterCursor]
            .contains { !($0 ?? "").isEmpty } || isEmptyField
    }
}

/// What the prompt may say about the moment recording started. Each field
/// is already gated and redacted; the renderer prints whatever is set.
struct PromptContext: Equatable, Sendable {
    var selectedText: String?
    var clipboardText: String?
    var system: SystemSnapshot?
    var user: UserIdentity?
    var application: ApplicationSnapshot?
}

/// Which context may reach the language model for one dictation.
struct ContextPolicy: Equatable, Sendable {
    /// The global "send context" switch (`destinationAwareRefinement`).
    /// Off sends no context at all, whatever the mode says.
    var sendsContext = true
    /// Cloud model with "keep field content on-device" on: selected text,
    /// clipboard and field text are dropped, and addresses keep only the site.
    var redactsUserText = false
    /// The user opted in to sharing their contact card.
    var includesIdentity = false
}

extension PromptContext {

    /// Gathers what `mode` asks for, within `policy`.
    ///
    /// - Selected text: the mode's selection toggle.
    /// - Clipboard: the mode's clipboard toggle (a copy from the last 3 s).
    /// - System, user and application details: the mode's application
    ///   toggle; user details also need the contact card opt-in. Identity is
    ///   sent to cloud models too, because the user turned it on explicitly.
    /// - Nothing is read from a secure (password) field.
    static func build(
        mode: Mode,
        destination: DictationContext?,
        clipboardText: String? = nil,
        system: SystemSnapshot? = nil,
        user: UserIdentity? = nil,
        catalog: AppCatalogEntry? = nil,
        policy: ContextPolicy
    ) -> PromptContext {
        var context = PromptContext()
        guard policy.sendsContext, ModePresets.usesLanguageModel(mode.type) else { return context }
        let secure = destination?.isSecureField ?? false
        let mayShareText = !policy.redactsUserText && !secure

        if mode.contextFromSelection, mayShareText {
            context.selectedText = nonEmpty(destination?.selectedText)
        }
        if mode.contextFromClipboard, !policy.redactsUserText {
            context.clipboardText = nonEmpty(clipboardText)
        }
        if mode.contextFromActiveApplication {
            context.system = system
            if policy.includesIdentity, let user, !user.isEmpty {
                context.user = user
            }
            if let destination {
                var app = ApplicationSnapshot()
                app.appName = nonEmpty(destination.appName)
                if let url = nonEmpty(destination.browserURL) {
                    app.url = policy.redactsUserText ? ModeActivation.siteOnly(url) : url
                }
                app.category = catalog?.category
                app.appDescription = catalog?.description
                app.inputFormat = catalog?.inputFormat?.promptName
                app.fieldRole = nonEmpty(destination.fieldRole)
                app.fieldLabel = nonEmpty(destination.fieldLabel)
                app.isEmptyField = destination.isEmptyField
                if mayShareText {
                    app.textBeforeCursor = nonEmpty(destination.textBeforeCursor)
                    app.textAfterCursor = nonEmpty(destination.textAfterCursor)
                }
                context.application = app.hasContent ? app : nil
            }
        }
        return context
    }

    /// The destination block Parrot sent before modes had context toggles:
    /// app, field, and the field's text. Used by the legacy
    /// `RefinementService.systemPrompt(directive:context:)`.
    static func legacy(_ destination: DictationContext?) -> PromptContext {
        guard let destination, destination.hasContent, !destination.isSecureField else { return PromptContext() }
        var app = ApplicationSnapshot()
        app.appName = nonEmpty(destination.appName)
        app.fieldRole = nonEmpty(destination.fieldRole)
        app.fieldLabel = nonEmpty(destination.fieldLabel)
        app.isEmptyField = destination.isEmptyField
        app.textBeforeCursor = nonEmpty(destination.textBeforeCursor)
        return PromptContext(selectedText: nonEmpty(destination.selectedText), application: app.hasContent ? app : nil)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}
