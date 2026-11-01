import Foundation

public struct Command: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?
    public var currentDirectory: String?
    public var stdin: Data?
    public var timeout: TimeInterval

    public init(_ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil, currentDirectory: String? = nil, stdin: Data? = nil, timeout: TimeInterval = 120) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.currentDirectory = currentDirectory; self.stdin = stdin; self.timeout = timeout
    }
}

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var duration: TimeInterval

    public init(exitCode: Int32, stdout: Data, stderr: Data, timedOut: Bool = false, duration: TimeInterval = 0) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut; self.duration = duration
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    /// Last 4 KB of stderr, for storing on a failed Run.
    public var errorTail: String { String(stderrText.suffix(4096)) }
}

public enum CommandError: Error, Sendable {
    case executableNotFound(String)
    case launchFailed(String)
}

public protocol CommandRunner: Sendable {
    /// `command.executable` may be a bare name (resolved through the runner's search path) or an absolute path.
    /// Never goes through a shell; arguments are passed verbatim.
    func run(_ command: Command) async throws -> CommandResult
}
