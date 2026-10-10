import Foundation

/// The kind of text a field expects, so the language model writes a chat
/// message, an email, code or a terminal command as appropriate. [LLM]
enum TextInputFormat: String, CaseIterable, Sendable {
    case chatMessage
    case email
    case code
    case terminal
    case document

    /// How the prompt names it.
    var promptName: String {
        switch self {
        case .chatMessage: return "chat message"
        case .email: return "email"
        case .code: return "code"
        case .terminal: return "terminal command"
        case .document: return "document text"
        }
    }
}

/// What Parrot knows about an app or website. [LLM]
struct AppCatalogEntry: Equatable, Sendable {
    var category: String
    var description: String?
    var inputFormat: TextInputFormat?
}

/// A group in the activation sheet ("Email", "Code") that adds its apps and
/// sites to a mode in one go.
struct ActivationCategory: Identifiable, Equatable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case email, chat, aiChat, documents, code, terminal, social, browsers
    }

    let group: Group
    let name: String
    let symbol: String
    /// Known apps in this group (installed or not).
    let bundleIDs: [String]
    let sites: [String]

    var id: String { group.rawValue }
}

/// Parrot's own app catalog: a small hand-written map of common apps and
/// sites, plus each app's `LSApplicationCategoryType` from its Info.plist
/// for everything else. [LLM]
enum AppCatalog {

    /// The entry for a dictation target. A known website wins (a browser
    /// showing Gmail is an email field), then the hand map, then the app's
    /// declared category. Nil when nothing is known.
    static func entry(bundleID: String?, appURL: URL? = nil, url: String? = nil) -> AppCatalogEntry? {
        if let url, let host = ModeActivation.host(of: url), let site = siteEntry(forHost: host) {
            return site
        }
        if let bundleID, let known = handMapped(bundleID: bundleID) {
            return known
        }
        if let appURL, let declared = declaredCategory(appURL: appURL) {
            return entry(forLSCategory: declared)
        }
        return nil
    }

    /// The hand-written entry for an app. JetBrains IDEs match by prefix.
    static func handMapped(bundleID: String) -> AppCatalogEntry? {
        let id = bundleID.lowercased()
        if let app = apps.first(where: { $0.bundleID.lowercased() == id }) {
            return app.entry
        }
        if id.hasPrefix("com.jetbrains.") {
            return AppCatalogEntry(category: "Code Editor", description: "JetBrains IDE", inputFormat: .code)
        }
        return nil
    }

    /// The entry for a website host (subdomains included).
    static func siteEntry(forHost host: String) -> AppCatalogEntry? {
        let host = host.lowercased()
        let matches = sites.filter { host == $0.host || host.hasSuffix("." + $0.host) }
        return matches.max { $0.host.count < $1.host.count }?.entry
    }

    /// `LSApplicationCategoryType` from an app bundle's Info.plist.
    static func declaredCategory(appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let category = info["LSApplicationCategoryType"] as? String, !category.isEmpty
        else { return nil }
        return category
    }

    /// A readable entry for an `LSApplicationCategoryType` value
    /// (`public.app-category.developer-tools`).
    static func entry(forLSCategory raw: String) -> AppCatalogEntry? {
        let suffix = raw.lowercased().replacingOccurrences(of: "public.app-category.", with: "")
        if suffix.hasSuffix("-games") || suffix == "games" {
            return AppCatalogEntry(category: "Games")
        }
        guard let known = lsCategories[suffix] else { return nil }
        return AppCatalogEntry(category: known.name, inputFormat: known.format)
    }

    /// The groups the activation sheet offers.
    static var activationCategories: [ActivationCategory] {
        ActivationCategory.Group.allCases.map { group in
            ActivationCategory(
                group: group,
                name: groupInfo[group]?.name ?? group.rawValue,
                symbol: groupInfo[group]?.symbol ?? "square.grid.2x2",
                bundleIDs: apps.filter { $0.group == group }.map(\.bundleID),
                sites: sites.filter { $0.group == group }.map(\.host)
            )
        }
    }

    // MARK: - Data

    private struct App {
        let bundleID: String
        let category: String
        let description: String
        let format: TextInputFormat?
        let group: ActivationCategory.Group

        var entry: AppCatalogEntry {
            AppCatalogEntry(category: category, description: description, inputFormat: format)
        }
    }

    private struct Site {
        let host: String
        let category: String
        let description: String
        let format: TextInputFormat?
        let group: ActivationCategory.Group

        var entry: AppCatalogEntry {
            AppCatalogEntry(category: category, description: description, inputFormat: format)
        }
    }

    private static let groupInfo: [ActivationCategory.Group: (name: String, symbol: String)] = [
        .email: ("Email", "envelope"),
        .chat: ("Chat", "bubble.left.and.bubble.right"),
        .aiChat: ("AI Chat", "sparkles"),
        .documents: ("Documents", "doc.text"),
        .code: ("Code", "chevron.left.forwardslash.chevron.right"),
        .terminal: ("Terminal", "terminal"),
        .social: ("Social Media", "person.2"),
        .browsers: ("Web Browsers", "globe"),
    ]

    private static let apps: [App] = [
        // Chat
        App(bundleID: "com.tinyspeck.slackmacgap", category: "Messaging (Work)", description: "Team chat", format: .chatMessage, group: .chat),
        App(bundleID: "com.microsoft.teams2", category: "Messaging (Work)", description: "Team chat and meetings", format: .chatMessage, group: .chat),
        App(bundleID: "com.microsoft.teams", category: "Messaging (Work)", description: "Team chat and meetings", format: .chatMessage, group: .chat),
        App(bundleID: "com.apple.MobileSMS", category: "Messaging", description: "Text messages", format: .chatMessage, group: .chat),
        App(bundleID: "com.hnc.Discord", category: "Messaging", description: "Community chat", format: .chatMessage, group: .chat),
        App(bundleID: "net.whatsapp.WhatsApp", category: "Messaging", description: "Personal messaging", format: .chatMessage, group: .chat),
        App(bundleID: "ru.keepcoder.Telegram", category: "Messaging", description: "Personal messaging", format: .chatMessage, group: .chat),
        App(bundleID: "org.whispersystems.signal-desktop", category: "Messaging", description: "Private messaging", format: .chatMessage, group: .chat),
        App(bundleID: "us.zoom.xos", category: "Video Meetings", description: "Meetings with chat", format: .chatMessage, group: .chat),
        // AI chat
        App(bundleID: "com.openai.chat", category: "AI Chat", description: "AI assistant chat", format: .chatMessage, group: .aiChat),
        App(bundleID: "com.anthropic.claudefordesktop", category: "AI Chat", description: "AI assistant chat", format: .chatMessage, group: .aiChat),
        // Email
        App(bundleID: "com.apple.mail", category: "Email", description: "Email client", format: .email, group: .email),
        App(bundleID: "com.microsoft.Outlook", category: "Email", description: "Email and calendar", format: .email, group: .email),
        App(bundleID: "com.readdle.smartemail-Mac", category: "Email", description: "Email client", format: .email, group: .email),
        App(bundleID: "com.superhuman.electron", category: "Email", description: "Email client", format: .email, group: .email),
        App(bundleID: "com.mimestream.Mimestream", category: "Email", description: "Email client", format: .email, group: .email),
        App(bundleID: "com.freron.MailMate", category: "Email", description: "Email client", format: .email, group: .email),
        // Code
        App(bundleID: "com.apple.dt.Xcode", category: "Code Editor", description: "Apple's IDE", format: .code, group: .code),
        App(bundleID: "com.microsoft.VSCode", category: "Code Editor", description: "Code editor", format: .code, group: .code),
        App(bundleID: "com.microsoft.VSCodeInsiders", category: "Code Editor", description: "Code editor", format: .code, group: .code),
        App(bundleID: "com.todesktop.230313mzl4w4u92", category: "Code Editor", description: "AI code editor (Cursor)", format: .code, group: .code),
        App(bundleID: "dev.zed.Zed", category: "Code Editor", description: "Code editor", format: .code, group: .code),
        App(bundleID: "com.sublimetext.4", category: "Code Editor", description: "Text and code editor", format: .code, group: .code),
        App(bundleID: "com.panic.Nova", category: "Code Editor", description: "Code editor", format: .code, group: .code),
        App(bundleID: "com.barebones.bbedit", category: "Code Editor", description: "Text and code editor", format: .code, group: .code),
        App(bundleID: "com.google.android.studio", category: "Code Editor", description: "Android IDE", format: .code, group: .code),
        // Terminal
        App(bundleID: "com.apple.Terminal", category: "Terminal", description: "Command line", format: .terminal, group: .terminal),
        App(bundleID: "com.googlecode.iterm2", category: "Terminal", description: "Command line", format: .terminal, group: .terminal),
        App(bundleID: "dev.warp.Warp-Stable", category: "Terminal", description: "Command line", format: .terminal, group: .terminal),
        App(bundleID: "com.mitchellh.ghostty", category: "Terminal", description: "Command line", format: .terminal, group: .terminal),
        App(bundleID: "net.kovidgoyal.kitty", category: "Terminal", description: "Command line", format: .terminal, group: .terminal),
        App(bundleID: "org.alacritty", category: "Terminal", description: "Command line", format: .terminal, group: .terminal),
        App(bundleID: "com.github.wez.wezterm", category: "Terminal", description: "Command line", format: .terminal, group: .terminal),
        // Documents and notes
        App(bundleID: "com.apple.iWork.Pages", category: "Document Editor", description: "Word processor", format: .document, group: .documents),
        App(bundleID: "com.microsoft.Word", category: "Document Editor", description: "Word processor", format: .document, group: .documents),
        App(bundleID: "com.apple.TextEdit", category: "Text Editor", description: "Plain and rich text", format: .document, group: .documents),
        App(bundleID: "com.apple.Notes", category: "Note Taking", description: "Notes", format: .document, group: .documents),
        App(bundleID: "notion.id", category: "Note Taking", description: "Notes and wikis", format: .document, group: .documents),
        App(bundleID: "md.obsidian", category: "Note Taking", description: "Markdown notes", format: .document, group: .documents),
        App(bundleID: "net.shinyfrog.bear", category: "Note Taking", description: "Markdown notes", format: .document, group: .documents),
        App(bundleID: "com.lukilabs.lukiapp", category: "Document Editor", description: "Documents and notes", format: .document, group: .documents),
        // Browsers (the site decides the format)
        App(bundleID: "com.apple.Safari", category: "Web Browser", description: "Web browser", format: nil, group: .browsers),
        App(bundleID: "com.google.Chrome", category: "Web Browser", description: "Web browser", format: nil, group: .browsers),
        App(bundleID: "org.mozilla.firefox", category: "Web Browser", description: "Web browser", format: nil, group: .browsers),
        App(bundleID: "company.thebrowser.Browser", category: "Web Browser", description: "Web browser", format: nil, group: .browsers),
        App(bundleID: "com.brave.Browser", category: "Web Browser", description: "Web browser", format: nil, group: .browsers),
        App(bundleID: "com.microsoft.edgemac", category: "Web Browser", description: "Web browser", format: nil, group: .browsers),
    ]

    private static let sites: [Site] = [
        Site(host: "mail.google.com", category: "Email", description: "Web email", format: .email, group: .email),
        Site(host: "outlook.live.com", category: "Email", description: "Web email", format: .email, group: .email),
        Site(host: "outlook.office.com", category: "Email", description: "Web email", format: .email, group: .email),
        Site(host: "mail.proton.me", category: "Email", description: "Web email", format: .email, group: .email),
        Site(host: "app.slack.com", category: "Messaging (Work)", description: "Team chat", format: .chatMessage, group: .chat),
        Site(host: "teams.microsoft.com", category: "Messaging (Work)", description: "Team chat", format: .chatMessage, group: .chat),
        Site(host: "discord.com", category: "Messaging", description: "Community chat", format: .chatMessage, group: .chat),
        Site(host: "web.whatsapp.com", category: "Messaging", description: "Personal messaging", format: .chatMessage, group: .chat),
        Site(host: "chatgpt.com", category: "AI Chat", description: "AI assistant chat", format: .chatMessage, group: .aiChat),
        Site(host: "claude.ai", category: "AI Chat", description: "AI assistant chat", format: .chatMessage, group: .aiChat),
        Site(host: "perplexity.ai", category: "AI Chat", description: "AI search chat", format: .chatMessage, group: .aiChat),
        Site(host: "gemini.google.com", category: "AI Chat", description: "AI assistant chat", format: .chatMessage, group: .aiChat),
        Site(host: "docs.google.com", category: "Document Editor", description: "Online documents", format: .document, group: .documents),
        Site(host: "notion.so", category: "Note Taking", description: "Notes and wikis", format: .document, group: .documents),
        Site(host: "github.com", category: "Code Hosting", description: "Code review and issues", format: nil, group: .code),
        Site(host: "x.com", category: "Social Media", description: "Short posts", format: nil, group: .social),
        Site(host: "linkedin.com", category: "Social Media", description: "Professional network", format: nil, group: .social),
        Site(host: "facebook.com", category: "Social Media", description: "Social network", format: nil, group: .social),
        Site(host: "reddit.com", category: "Social Media", description: "Forums", format: nil, group: .social),
    ]

    private static let lsCategories: [String: (name: String, format: TextInputFormat?)] = [
        "developer-tools": ("Developer Tools", .code),
        "productivity": ("Productivity", .document),
        "business": ("Business", .document),
        "education": ("Education", .document),
        "social-networking": ("Social Networking", .chatMessage),
        "reference": ("Reference", nil),
        "utilities": ("Utilities", nil),
        "graphics-design": ("Design", nil),
        "photography": ("Photography", nil),
        "video": ("Video", nil),
        "music": ("Music", nil),
        "news": ("News", nil),
        "finance": ("Finance", nil),
        "lifestyle": ("Lifestyle", nil),
        "entertainment": ("Entertainment", nil),
        "travel": ("Travel", nil),
        "sports": ("Sports", nil),
        "weather": ("Weather", nil),
        "healthcare-fitness": ("Health and Fitness", nil),
        "medical": ("Medical", nil),
    ]
}
