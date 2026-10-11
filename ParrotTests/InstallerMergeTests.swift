import XCTest
@testable import Parrot

/// Installs and removes Parrot's hooks in temp copies of Claude Code's
/// settings and Codex's hooks file. Never reads or writes the real
/// `~/.claude` or `~/.codex`.
final class InstallerMergeTests: XCTestCase {

    private var temp: URL!
    private var installer: AgentInstaller!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-installer-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let bin = temp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        installer = AgentInstaller(
            claudeSettings: temp.appendingPathComponent("claude/settings.json"),
            codexHooks: temp.appendingPathComponent("codex/hooks.json"),
            helper: temp.appendingPathComponent("Parrot's App.app/Contents/MacOS/parrot-agent-hook"),
            searchDirectories: [temp.appendingPathComponent("missing"), bin],
            now: { Date(timeIntervalSince1970: 1_760_000_000) }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private let claudeOriginal = """
        {
          "model": "opus",
          "permissions": {"allow": ["Bash(npm test)"], "deny": []},
          "env": {"FOO": "bar"},
          "hooks": {
            "Stop": [
              {"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"}]}
            ],
            "PreToolUse": [
              {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/policy.sh", "timeout": 30}]}
            ]
          },
          "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}
        }
        """

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func object(_ url: URL) throws -> NSDictionary {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func object(_ text: String) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    private func groups(_ root: NSDictionary, _ event: String) -> [[String: Any]] {
        ((root["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    // MARK: - Claude Code

    func testClaudeInstallKeepsEverythingElse() throws {
        try write(claudeOriginal, to: installer.claudeSettings)
        let backup = try XCTUnwrap(try installer.install(.claude))
        let root = try object(installer.claudeSettings)

        // Unrelated keys survive untouched.
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual(root["env"] as? NSDictionary, ["FOO": "bar"])
        XCTAssertEqual((root["permissions"] as? NSDictionary)?["allow"] as? [String], ["Bash(npm test)"])
        XCTAssertNotNil(root["statusLine"])

        // The user's own hooks stay, Parrot's are added after them.
        let stop = groups(root, "Stop")
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String, "afplay /System/Library/Sounds/Glass.aiff")
        let parrotStop = try XCTUnwrap((stop[1]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(parrotStop["type"] as? String, "command")
        XCTAssertEqual(parrotStop["command"] as? String, installer.command(for: .claude))
        XCTAssertEqual(parrotStop["timeout"] as? Int, AgentInstaller.hookTimeout)

        let preTool = groups(root, "PreToolUse")
        XCTAssertEqual(preTool.map { $0["matcher"] as? String }, ["Bash", "AskUserQuestion|ExitPlanMode"])
        XCTAssertEqual(groups(root, "PermissionRequest").count, 1)
        XCTAssertNil(groups(root, "PermissionRequest")[0]["matcher"], "every tool")
        XCTAssertEqual(groups(root, "UserPromptSubmit").count, 1)
        XCTAssertTrue(installer.isInstalled(.claude))
        XCTAssertFalse(installer.needsUpdate(.claude))

        // The backup is the original file, byte for byte.
        XCTAssertEqual(backup.lastPathComponent.hasPrefix("settings.json.parrot-backup-"), true)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), claudeOriginal)
    }

    func testReinstallIsIdempotent() throws {
        try write(claudeOriginal, to: installer.claudeSettings)
        try installer.install(.claude)
        let first = try object(installer.claudeSettings)
        try installer.install(.claude)
        XCTAssertEqual(try object(installer.claudeSettings), first)
        XCTAssertEqual(installer.installedCommands(.claude).count, 4, "one handler per event, no duplicates")

        // Two installs, two distinct backups.
        let backups = try FileManager.default.contentsOfDirectory(atPath: installer.claudeSettings.deletingLastPathComponent().path)
            .filter { $0.contains(".parrot-backup-") }
        XCTAssertEqual(backups.count, 2)
    }

    func testRemoveRestoresTheOriginal() throws {
        try write(claudeOriginal, to: installer.claudeSettings)
        try installer.install(.claude)
        let backup = try XCTUnwrap(try installer.remove(.claude))
        XCTAssertEqual(try object(installer.claudeSettings), try object(claudeOriginal))
        XCTAssertFalse(installer.isInstalled(.claude))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertNil(try installer.remove(.claude), "nothing left to remove")
    }

    func testFreshFileInstallAndRemoveLeavesNoHooksKey() throws {
        XCTAssertNil(try installer.install(.claude), "no file, no backup")
        XCTAssertEqual(groups(try object(installer.claudeSettings), "Stop").count, 1)
        try installer.remove(.claude)
        XCTAssertEqual(try object(installer.claudeSettings), [:])
    }

    func testInvalidJSONIsNeverTouched() throws {
        let broken = "{ \"model\": \"opus\", // a comment\n"
        try write(broken, to: installer.claudeSettings)
        XCTAssertThrowsError(try installer.install(.claude)) { error in
            XCTAssertEqual(error as? AgentInstaller.InstallError, .unreadable(installer.claudeSettings.path))
        }
        XCTAssertEqual(try String(contentsOf: installer.claudeSettings, encoding: .utf8), broken)
        let backups = try FileManager.default.contentsOfDirectory(atPath: installer.claudeSettings.deletingLastPathComponent().path)
        XCTAssertEqual(backups, ["settings.json"], "no backup or temp file left behind")

        try write("[1, 2]", to: installer.claudeSettings)
        XCTAssertThrowsError(try installer.install(.claude))
    }

    func testSymlinkedSettingsStayALink() throws {
        let real = temp.appendingPathComponent("dotfiles/settings.json")
        try write(#"{"model": "opus"}"#, to: real)
        try FileManager.default.createDirectory(at: installer.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installer.claudeSettings, withDestinationURL: real)
        try installer.install(.claude)
        let attributes = try FileManager.default.attributesOfItem(atPath: installer.claudeSettings.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(groups(try object(real), "Stop").count, 1)
    }

    func testOldHelperPathNeedsUpdate() throws {
        let stale = """
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "'/Old/Parrot.app/Contents/MacOS/parrot-agent-hook' claude"}]}]}}
            """
        try write(stale, to: installer.claudeSettings)
        XCTAssertTrue(installer.needsUpdate(.claude))
        try installer.install(.claude)
        XCTAssertFalse(installer.needsUpdate(.claude))
        XCTAssertFalse(installer.installedCommands(.claude).contains { $0.contains("/Old/") })
    }

    // MARK: - Codex

    func testCodexInstallAndRemove() throws {
        let original = """
            {
              "description": "Team hooks",
              "hooks": {
                "SessionStart": [{"matcher": "startup|resume", "hooks": [{"type": "command", "command": "python3 ~/.codex/hooks/session_start.py"}]}],
                "Stop": [{"hooks": [{"type": "command", "command": "./stop_continue.py", "timeout": 30}]}]
              }
            }
            """
        try write(original, to: installer.codexHooks)
        try installer.install(.codex)
        let root = try object(installer.codexHooks)
        XCTAssertEqual(root["description"] as? String, "Team hooks")
        XCTAssertEqual(groups(root, "SessionStart").count, 1)
        XCTAssertEqual(groups(root, "Stop").count, 2)
        XCTAssertEqual(groups(root, "PermissionRequest").count, 1)
        XCTAssertTrue(groups(root, "PreToolUse").isEmpty, "Codex documents no question or plan tool")
        let handler = try XCTUnwrap((groups(root, "PermissionRequest")[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(handler["command"] as? String, installer.command(for: .codex))
        XCTAssertTrue((handler["command"] as? String)?.hasSuffix(" codex") ?? false)

        try installer.remove(.codex)
        XCTAssertEqual(try object(installer.codexHooks), try object(original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.claudeSettings.path), "Claude's file is never created by a Codex install")
    }

    // MARK: - Commands and Detection

    func testCommandQuotesTheHelperPath() {
        XCTAssertEqual(
            installer.command(for: .claude),
            "'\(temp.path)/Parrot'\\''s App.app/Contents/MacOS/parrot-agent-hook' claude"
        )
    }

    func testFindsCLIsInSearchDirectories() throws {
        XCTAssertNil(installer.findCLI(.claude))
        let claude = temp.appendingPathComponent("bin/claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        XCTAssertEqual(installer.findCLI(.claude)?.path, claude.path)
        XCTAssertNil(installer.findCLI(.codex))
        XCTAssertFalse(installer.helperExists)
    }

    func testLiveInstallerPointsAtHomeDotfiles() {
        // Paths only: nothing is read or written.
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let live = AgentInstaller.live(home: home)
        XCTAssertEqual(live.claudeSettings.path, "/Users/example/.claude/settings.json")
        XCTAssertEqual(live.codexHooks.path, "/Users/example/.codex/hooks.json")
        XCTAssertEqual(live.helper.lastPathComponent, "parrot-agent-hook")
    }
}
