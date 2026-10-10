import Foundation

// parrot-agent-hook: the helper Claude Code and Codex hooks run to reach
// Parrot. Usage: `parrot-agent-hook <claude|codex>` with the hook event JSON
// on stdin. See AgentHookProtocol.swift for the wire format and the vendor
// documentation it follows.
//
// Rule one: never break or stall the CLI. Every failure path and every wait
// ends with exit code 0 and nothing on stdout, which both CLIs read as "no
// decision", so their own terminal prompt takes over.
//
// Rule two: agent messages and tool inputs can hold source code and
// secrets. Folders must be 0700, owned by the user and not symlinks (or the
// helper exits); files are created 0600 and deleted once handled; the
// fallback link carries only ids and names; nothing is logged.

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

/// Files this run created, removed on every exit after the request is out.
var ownFiles: [URL] = []

func finish(_ output: HookJSON? = nil) -> Never {
    for file in ownFiles { unlink(file.path) }
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

// Session markers: a control folder that is not ours means stop here.
let controlCheck = AgentHookPaths.secureDirectory(paths.controlDir, create: false)
if controlCheck == .insecure { finish() }
let markersTrusted = controlCheck == .secure

// Parrot creates the agent folder when the feature is set up; missing or
// not ours, there is nobody to ask.
guard AgentHookPaths.secureDirectory(paths.agentDir, create: false) == .secure else { finish() }

func markerExists(_ url: URL) -> Bool {
    markersTrusted && FileManager.default.fileExists(atPath: url.path)
}

/// The app's shared state, or nil when Parrot never turned the feature on.
func loadState() -> AgentHookState? {
    guard AgentHookPaths.isPrivateFile(paths.stateFile),
          let data = try? Data(contentsOf: paths.stateFile)
    else { return nil }
    return try? JSONDecoder().decode(AgentHookState.self, from: data)
}

/// True when Parrot is running with agent replies on.
func appIsListening(_ state: AgentHookState?) -> Bool {
    guard let state, state.enabled else { return false }
    return agentHookProcessIsAlive(state.appPid)
}

/// Drops `message` into the inbox (0600) and returns the file, or nil.
func writeInbox(_ message: AgentInboxMessage) -> URL? {
    guard AgentHookPaths.secureDirectory(paths.inbox, create: true) == .secure else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(message) else { return nil }
    let request = message.requestId.isEmpty ? UUID().uuidString : message.requestId
    let name = "\(Int64(message.createdAt * 1000))-\(AgentHookPaths.safeName(request))-\(message.kind.rawValue).json"
    let file = paths.inbox.appendingPathComponent(name)
    do {
        try AgentHookPaths.writeAtomically(data, to: file)
        return file
    } catch {
        return nil
    }
}

/// Tells Parrot through a `parrot://` link, the fallback when the inbox
/// cannot be written. The link holds only ids and names. Waits at most five
/// seconds for the opener.
func openDeepLink(_ message: AgentInboxMessage) {
    guard let url = AgentDeepLink(message: message).url else { return }
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

// MARK: - UserPromptSubmit: re-enable phrase, and the user is back in the terminal

if input.hookEventName == "UserPromptSubmit" {
    let disabled = paths.disabledMarker(sessionId: input.sessionId)
    if let prompt = input.prompt, AgentHookPhrases.isEnable(prompt) {
        if markerExists(disabled) { try? FileManager.default.removeItem(at: disabled) }
        finish(HookDecision.blockPrompt(reason: "Parrot is on again for this session."))
    }
    // Typing in the terminal answers whatever Parrot was showing for this
    // session, so take its card down. Inbox only: a link cannot carry it.
    if !markerExists(disabled), appIsListening(loadState()) {
        _ = writeInbox(.dismiss(agent: agent, sessionId: input.sessionId, requestId: "", hookPid: pid))
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

guard AgentHookPaths.secureDirectory(paths.responses, create: true) == .secure else { finish() }

let requestId = UUID().uuidString
guard let responseFile = paths.responseFile(requestId: requestId) else { finish() }
ownFiles.append(responseFile)

var update = AgentInboxMessage.update(
    agent: agent, event: event, input: input, requestId: requestId, hookPid: pid,
    branch: input.cwd.flatMap(AgentHookGit.branch(at:))
)
if let text = update.message, text.count > AgentInboxMessage.inlineLimit,
   AgentHookPaths.secureDirectory(paths.messages, create: true) == .secure,
   let file = paths.messageFile(requestId: requestId),
   (try? AgentHookPaths.writeAtomically(Data(text.utf8), to: file)) != nil {
    ownFiles.append(file)
    update.messageInFile = true
    update.message = String(text.prefix(AgentInboxMessage.inlineLimit))
}
if let file = writeInbox(update) {
    ownFiles.append(file)
} else {
    openDeepLink(update)
}

// MARK: - Wait for the answer

let timeout = environment[AgentHookPaths.timeoutVariable].flatMap(Double.init) ?? state.responseTimeout
let deadline = Date().addingTimeInterval(max(1, timeout))
var nextAppCheck = Date().addingTimeInterval(2)
var unreadable = 0

while Date() < deadline {
    if AgentHookPaths.isPrivateFile(responseFile), let data = try? Data(contentsOf: responseFile) {
        if let response = try? JSONDecoder().decode(AgentHookResponse.self, from: data), response.requestId == requestId {
            finish(HookDecision.output(agent: agent, event: event, input: input, response: response))
        }
        unreadable += 1
        if unreadable > 20 {
            unlink(responseFile.path)
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
// (`finish` also deletes this request's unread inbox and message files.)
_ = writeInbox(.dismiss(agent: agent, sessionId: input.sessionId, requestId: requestId, hookPid: pid))
finish()
