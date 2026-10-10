import Foundation

// parrot-agent-hook: the helper coding-agent hooks run to reach Parrot.
// Stub: prints usage and exits 0 so an installed hook never blocks an agent.

let usage = """
    usage: parrot-agent-hook <claude|codex>

    Reads a hook event as JSON on stdin and hands it to Parrot.
    Not implemented yet: this build only prints this message.
    """

FileHandle.standardError.write(Data((usage + "\n").utf8))
exit(0)
