import Foundation

// parrot-agent-hook: the helper Claude Code and Codex hooks run to reach
// Parrot. Usage: `parrot-agent-hook <claude|codex>` with the hook event JSON
// on stdin. See AgentHookProtocol.swift for the wire format and the vendor
// documentation it follows.
//
// Rule one: never break or stall the CLI. Every failure path and every wait
// ends with exit code 0 and nothing on stdout, which both CLIs read as "no
// decision", so their own terminal prompt takes over.

let usage = """
    usage: parrot-agent-hook <claude|codex>

    Reads a Claude Code or Codex hook event as JSON on stdin, shows it in
    Parrot, waits for the answer and prints the decision JSON the CLI expects.
    """

let environment = ProcessInfo.processInfo.environment
let arguments = CommandLine.arguments
let pid = getpid()

/// Seconds between checks for the response file.
let pollInterval: TimeInterval = 0.15

func finish(_ output: HookJSON? = nil) -> Never {
    if let output {
        var data = HookDecision.encode(output)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
    exit(0)
}

guard arguments.count >= 2, let agent = HookAgent(rawValue: arguments[1].lowercased()) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    finish()
}

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard let input = try? JSONDecoder().decode(HookInput.self, from: stdinData) else { finish() }

let paths = AgentHookPaths.resolve(environment: environment)
let markersTrusted = paths.controlDirIsTrusted

func markerExists(_ url: URL) -> Bool {
    markersTrusted && FileManager.default.fileExists(atPath: url.path)
}

/// The app's shared state, or nil when Parrot never turned the feature on.
func loadState() -> AgentHookState? {
    guard let data = try? Data(contentsOf: paths.stateFile) else { return nil }
    return try? JSONDecoder().decode(AgentHookState.self, from: data)
}

/// True when Parrot is running with agent replies on.
func appIsListening(_ state: AgentHookState?) -> Bool {
    guard let state, state.enabled else { return false }
    return agentHookProcessIsAlive(state.appPid)
}

/// Drops `message` into the inbox; false when that fails.
func writeInbox(_ message: AgentInboxMessage) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(message) else { return false }
    let name = "\(Int64(message.createdAt * 1000))-\(AgentHookPaths.safeName(message.requestId))-\(message.kind.rawValue).json"
    do {
        try AgentHookPaths.writeAtomically(data, to: paths.inbox.appendingPathComponent(name))
        return true
    } catch {
        return false
    }
}

/// Hands `message` to Parrot through a `parrot://` link, the fallback when
/// the inbox cannot be written. Waits at most five seconds for the opener.
func openDeepLink(_ message: AgentInboxMessage) {
    guard let url = message.deepLink else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: environment[AgentHookPaths.openerVariable] ?? "/usr/bin/open")
    process.arguments = [url.absoluteString]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning { process.terminate() }
}

func deliver(_ message: AgentInboxMessage) {
    if !writeInbox(message) { openDeepLink(message) }
}

// MARK: - UserPromptSubmit: re-enable phrase, and the user is back in the terminal

if input.hookEventName == "UserPromptSubmit" {
    let disabled = paths.disabledMarker(sessionId: input.sessionId)
    if let prompt = input.prompt, AgentHookPhrases.isEnable(prompt) {
        if markerExists(disabled) { try? FileManager.default.removeItem(at: disabled) }
        finish(HookDecision.blockPrompt(reason: "Parrot is on again for this session."))
    }
    // Typing in the terminal answers whatever Parrot was showing for this
    // session, so take its card down.
    if !markerExists(disabled), appIsListening(loadState()) {
        deliver(.dismiss(agent: agent, sessionId: input.sessionId, requestId: "", hookPid: pid))
    }
    finish()
}

// MARK: - Requests

if markerExists(paths.disabledMarker(sessionId: input.sessionId)) { finish() }

guard let event = input.event(for: agent) else { finish() }

guard let state = loadState(), appIsListening(state) else { finish() }

// Parrot's per-session bypass: allow without asking.
if event == .permission, markerExists(paths.bypassMarker(sessionId: input.sessionId)) {
    finish(HookDecision.output(
        agent: agent, event: event, input: input,
        response: AgentHookResponse(requestId: "", action: .allow)
    ))
}

let requestId = UUID().uuidString
let responseFile = paths.responseFile(requestId: requestId)
try? FileManager.default.removeItem(at: responseFile)

var update = AgentInboxMessage.update(
    agent: agent, event: event, input: input, requestId: requestId,
    responseFile: responseFile.path, hookPid: pid,
    branch: input.cwd.flatMap(AgentHookGit.branch(at:))
)
if let text = update.message, text.count > AgentInboxMessage.inlineLimit {
    let file = paths.messages.appendingPathComponent(AgentHookPaths.safeName(requestId) + ".md")
    if (try? AgentHookPaths.writeAtomically(Data(text.utf8), to: file)) != nil {
        update.messageFile = file.path
        update.message = String(text.prefix(AgentInboxMessage.inlineLimit))
    }
}
deliver(update)

// MARK: - Wait for the answer

let timeout = environment[AgentHookPaths.timeoutVariable].flatMap(Double.init) ?? state.responseTimeout
let deadline = Date().addingTimeInterval(max(1, timeout))
var nextAppCheck = Date().addingTimeInterval(2)
var unreadable = 0

while Date() < deadline {
    if let data = try? Data(contentsOf: responseFile) {
        if let response = try? JSONDecoder().decode(AgentHookResponse.self, from: data), response.requestId == requestId {
            try? FileManager.default.removeItem(at: responseFile)
            finish(HookDecision.output(agent: agent, event: event, input: input, response: response))
        }
        unreadable += 1
        if unreadable > 20 {
            try? FileManager.default.removeItem(at: responseFile)
            unreadable = 0
        }
    }
    if Date() >= nextAppCheck {
        // Parrot quit or the feature was turned off: stop holding the CLI.
        if !appIsListening(loadState()) { break }
        nextAppCheck = Date().addingTimeInterval(2)
    }
    Thread.sleep(forTimeInterval: pollInterval)
}

// No answer: take the card down and let the CLI's own prompt take over.
_ = writeInbox(.dismiss(agent: agent, sessionId: input.sessionId, requestId: requestId, hookPid: pid))
try? FileManager.default.removeItem(at: responseFile)
finish()
