import Foundation

// MARK: - AppleScriptMacro

/// Fills a mode's AppleScript with the dictated text. Pure. [OUT]
enum AppleScriptMacro {
    /// Replaced by the final text, escaped for an AppleScript string literal.
    static let userMessage = "{{user_message}}"

    /// `script` with every `{{user_message}}` replaced by the escaped text.
    static func render(script: String, userMessage text: String) -> String {
        script.replacingOccurrences(of: userMessage, with: escape(text))
    }

    /// Escapes text for use inside a double-quoted AppleScript string:
    /// backslash, quote, line feed, return and tab. The result stays on one
    /// line.
    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

// MARK: - AppleScriptRunner

/// Runs AppleScript source through `/usr/bin/osascript`, so a slow or stuck
/// script can be stopped after a timeout. [OUT]
struct AppleScriptRunner: Sendable {

    enum Failure: LocalizedError, Equatable {
        case timedOut(TimeInterval)
        case failed(status: Int32, message: String)
        case launch(String)

        var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "The script did not finish within \(Int(seconds)) seconds."
            case .failed(_, let message):
                return message.isEmpty ? "The script failed." : message
            case .launch(let message):
                return "The script could not start: \(message)"
            }
        }
    }

    var executable = URL(fileURLWithPath: "/usr/bin/osascript")
    var timeout: TimeInterval = 10

    init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    /// Runs `source` and returns what it printed. Throws on a non-zero exit,
    /// a launch failure or the timeout.
    func run(_ source: String) async throws -> String {
        let process = Process()
        process.executableURL = executable
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let timedOut = TimeoutFlag()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: Failure.launch(error.localizedDescription))
                return
            }
            // osascript reads the whole program from stdin before running it.
            // No SIGPIPE if it exits early: the write just fails.
            let writer = input.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? writer.write(contentsOf: Data(source.utf8))
            try? writer.close()

            let seconds = timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
        }

        if timedOut.isSet {
            throw Failure.timedOut(timeout)
        }
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.failed(status: status, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return printed.trimmingCharacters(in: .newlines)
    }
}

/// Set once from the timeout timer, read after the process exits.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
