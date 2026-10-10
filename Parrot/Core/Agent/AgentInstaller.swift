import Foundation

/// Adds and removes Parrot's hook entries in Claude Code's settings and
/// Codex's hooks file. [AGT]
///
/// Runs only when the user presses Install or Remove in the Agents tab.
/// Every unrelated key is kept; the file is backed up with a timestamp
/// first; a file that is not valid JSON is never touched. Parrot's entries
/// are recognised by the helper name in their command, so installing again
/// replaces them instead of adding duplicates.
///
/// Hook shapes follow https://code.claude.com/docs/en/hooks (settings.json
/// `hooks`: event, matcher group, command handler) and
/// https://developers.openai.com/codex/hooks (`~/.codex/hooks.json`, same
/// nesting). Codex runs a new hook only after the user trusts it with
/// `/hooks`.
struct AgentInstaller {

    enum InstallError: LocalizedError, Equatable {
        case unreadable(String)
        case notAnObject(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "\(path) is not valid JSON. Parrot left it unchanged."
            case .notAnObject(let path): return "\(path) does not hold a JSON object. Parrot left it unchanged."
            }
        }
    }

    /// Claude Code's user settings, `~/.claude/settings.json`.
    var claudeSettings: URL
    /// Codex's user hooks, `~/.codex/hooks.json`.
    var codexHooks: URL
    /// The helper binary the hooks run.
    var helper: URL
    /// Folders searched for the `claude` and `codex` binaries.
    var searchDirectories: [URL]
    var now: () -> Date = Date.init

    /// Text in a hook command that marks it as Parrot's.
    static let marker = "parrot-agent-hook"
    /// The CLI-side hook timeout in seconds: the longest response timeout
    /// plus a minute, so the helper always gives up first.
    static let hookTimeout = Int(AgentSettings.timeoutRange.upperBound) + 60

    /// The real paths. Only the Agents tab uses this, after a button press.
    static func live(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentInstaller {
        let helper = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("parrot-agent-hook")
            ?? URL(fileURLWithPath: "/Applications/Parrot.app/Contents/MacOS/parrot-agent-hook")
        var directories = [
            ".local/bin", ".npm-global/bin", ".volta/bin", ".bun/bin", ".claude/local", ".codex/bin",
        ].map { home.appendingPathComponent($0, isDirectory: true) }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let nvm = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            directories += versions.map { $0.appendingPathComponent("bin", isDirectory: true) }
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        directories += path.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        return AgentInstaller(
            claudeSettings: home.appendingPathComponent(".claude/settings.json"),
            codexHooks: home.appendingPathComponent(".codex/hooks.json"),
            helper: helper,
            searchDirectories: directories
        )
    }

    // MARK: - Status

    func settingsFile(for agent: HookAgent) -> URL {
        switch agent {
        case .claude: return claudeSettings
        case .codex: return codexHooks
        }
    }

    /// The installed CLI binary, if any.
    func findCLI(_ agent: HookAgent) -> URL? {
        let name = agent == .claude ? "claude" : "codex"
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    var helperExists: Bool {
        FileManager.default.isExecutableFile(atPath: helper.path)
    }

    /// The hook command Parrot installs for `agent`.
    func command(for agent: HookAgent) -> String {
        "'\(helper.path.replacingOccurrences(of: "'", with: "'\\''"))' \(agent.rawValue)"
    }

    /// Parrot's commands found in the agent's settings file.
    func installedCommands(_ agent: HookAgent) -> [String] {
        guard let root = try? read(settingsFile(for: agent)) else { return [] }
        return Self.parrotCommands(in: root)
    }

    func isInstalled(_ agent: HookAgent) -> Bool {
        !installedCommands(agent).isEmpty
    }

    /// Installed, but pointing at a different helper (the app moved).
    func needsUpdate(_ agent: HookAgent) -> Bool {
        let commands = installedCommands(agent)
        return !commands.isEmpty && commands.contains { $0 != command(for: agent) }
    }

    // MARK: - Install and Remove

    /// Adds Parrot's hooks for `agent`, replacing older Parrot entries.
    /// Returns the backup it made (nil when the file did not exist).
    @discardableResult
    func install(_ agent: HookAgent) throws -> URL? {
        // Write through a symlinked settings file (dotfile setups) instead of
        // replacing the link.
        let file = settingsFile(for: agent).resolvingSymlinksInPath()
        let root = try read(file) ?? [:]
        let backup = try backUp(file)
        let updated = Self.merged(Self.removingParrot(from: root), adding: Self.entries(for: agent, command: command(for: agent)))
        try write(updated, to: file)
        return backup
    }

    /// Removes Parrot's hooks for `agent` and nothing else. Returns the
    /// backup it made (nil when there was nothing to remove).
    @discardableResult
    func remove(_ agent: HookAgent) throws -> URL? {
        let file = settingsFile(for: agent).resolvingSymlinksInPath()
        guard let root = try read(file), !Self.parrotCommands(in: root).isEmpty else { return nil }
        let backup = try backUp(file)
        try write(Self.removingParrot(from: root), to: file)
        return backup
    }

    // MARK: - JSON Merge

    /// Parrot's matcher groups per hook event.
    static func entries(for agent: HookAgent, command: String) -> [String: [[String: Any]]] {
        func handler(timeout: Int, status: String?) -> [String: Any] {
            var handler: [String: Any] = ["type": "command", "command": command, "timeout": timeout]
            if let status { handler["statusMessage"] = status }
            return handler
        }
        let waiting = handler(timeout: hookTimeout, status: "Waiting for your answer in Parrot")
        // Quick: only handles "enable parrot" and takes Parrot's card down.
        let prompt = handler(timeout: 10, status: nil)
        var entries: [String: [[String: Any]]] = [
            "Stop": [["hooks": [waiting]]],
            "PermissionRequest": [["hooks": [waiting]]],
            "UserPromptSubmit": [["hooks": [prompt]]],
        ]
        if agent == .claude {
            entries["PreToolUse"] = [["matcher": "AskUserQuestion|ExitPlanMode", "hooks": [waiting]]]
        }
        return entries
    }

    /// `root` with `entries` appended to its `hooks` object.
    static func merged(_ root: [String: Any], adding entries: [String: [[String: Any]]]) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, groups) in entries {
            let existing = hooks[event] as? [Any] ?? []
            hooks[event] = existing + groups.map { $0 as Any }
        }
        root["hooks"] = hooks
        return root
    }

    /// `root` without any handler whose command names the helper. Groups,
    /// events and the `hooks` object left empty by that are removed too.
    static func removingParrot(from root: [String: Any]) -> [String: Any] {
        guard let hooks = root["hooks"] as? [String: Any] else { return root }
        var root = root
        var cleaned = hooks
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            var changed = false
            let kept: [Any] = groups.compactMap { item in
                guard var group = item as? [String: Any], let handlers = group["hooks"] as? [Any] else { return item }
                let remaining = handlers.filter { !isParrot($0) }
                guard remaining.count != handlers.count else { return item }
                changed = true
                if remaining.isEmpty { return nil }
                group["hooks"] = remaining
                return group
            }
            guard changed else { continue }
            cleaned[event] = kept.isEmpty ? nil : kept
        }
        if cleaned.isEmpty {
            root["hooks"] = nil
        } else {
            root["hooks"] = cleaned
        }
        return root
    }

    static func parrotCommands(in root: [String: Any]) -> [String] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        var commands: [String] = []
        for value in hooks.values {
            for group in value as? [Any] ?? [] {
                for handler in (group as? [String: Any])?["hooks"] as? [Any] ?? [] where isParrot(handler) {
                    if let command = (handler as? [String: Any])?["command"] as? String { commands.append(command) }
                }
            }
        }
        return commands
    }

    private static func isParrot(_ handler: Any) -> Bool {
        ((handler as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }

    // MARK: - Files

    /// The file's JSON object, nil when the file does not exist.
    private func read(_ file: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw InstallError.unreadable(file.path)
        }
        guard let dictionary = object as? [String: Any] else { throw InstallError.notAnObject(file.path) }
        return dictionary
    }

    /// Copies `file` to `<name>.parrot-backup-<yyyyMMdd-HHmmss>` beside it.
    private func backUp(_ file: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now())
        var backup = file.deletingLastPathComponent().appendingPathComponent("\(file.lastPathComponent).parrot-backup-\(stamp)")
        var counter = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = file.deletingLastPathComponent().appendingPathComponent("\(file.lastPathComponent).parrot-backup-\(stamp)-\(counter)")
            counter += 1
        }
        try FileManager.default.copyItem(at: file, to: backup)
        return backup
    }

    private func write(_ root: [String: Any], to file: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try AgentHookPaths.writeAtomically(data, to: file)
    }
}
