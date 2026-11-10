import Foundation
import os

public struct ProcessRunner: CommandRunner {
    public static let defaultInheritedKeys: Set<String> = ["SSH_AUTH_SOCK", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "SHELL"]
    static let forbiddenKeys: Set<String> = ["GH_TOKEN", "GITHUB_TOKEN"]
    static let redactedFlags: Set<String> = ["--prompt", "--text"]

    public let searchPath: [String]
    private let inherited: [String: String]
    private static let logger = Logger(subsystem: "io.github.cure-tmk.pilotboat", category: "process")

    /// The child sees `PATH` (from `searchPath`), `HOME`, the `inheritedKeys` present in this process's environment,
    /// and `Command.environment`; `GH_TOKEN` and `GITHUB_TOKEN` are always removed.
    public init(searchPath: [String], inheritedKeys: Set<String> = ProcessRunner.defaultInheritedKeys) {
        self.searchPath = searchPath
        inherited = ProcessInfo.processInfo.environment.filter { inheritedKeys.contains($0.key) }
    }

    public func run(_ command: Command) async throws -> CommandResult {
        guard let path = PathResolver.find(command.executable, in: searchPath) else {
            throw CommandError.executableNotFound(command.executable)
        }
        var env = inherited
        env["PATH"] = searchPath.joined(separator: ":")
        env["HOME"] = NSHomeDirectory()
        env.merge(command.environment ?? [:]) { $1 }
        for key in Self.forbiddenKeys { env[key] = nil }
        let job = Job(path: path, command: command, environment: env)
        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
            DispatchQueue.global().async { cont.resume(with: Result { try job.execute() }) }
        }
        let args = Self.loggedArguments(command.arguments)
        Self.logger.info("\(path, privacy: .public) \(args, privacy: .public) exit=\(result.exitCode) duration=\(result.duration)s timedOut=\(result.timedOut)")
        return result
    }

    static func loggedArguments(_ arguments: [String]) -> String {
        zip([""] + arguments, arguments)
            .map { redactedFlags.contains($0) ? "<redacted>" : String($1.prefix(200)) }
            .joined(separator: " ")
    }
}

private final class Job: @unchecked Sendable {
    let process = Process()
    let timeout: TimeInterval
    let stdin: Data?
    private let lock = NSLock()
    private var timedOut = false
    private var outData = Data()
    private var errData = Data()

    init(path: String, command: Command, environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = command.arguments
        process.environment = environment
        if let cwd = command.currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        timeout = command.timeout
        stdin = command.stdin
    }

    func execute() throws -> CommandResult {
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        let start = Date()
        do { try process.run() } catch { throw CommandError.launchFailed("\(error)") }
        let deadline = DispatchTime.now() + timeout

        // Read sources rather than blocking reads: a grandchild that inherited stdout can hold the pipe open
        // indefinitely, and a cancelled source lets us stop waiting without closing an fd another thread is reading.
        let group = DispatchGroup()
        let sources = [(out, true), (err, false)].map { pipe, isOut in
            let fd = pipe.fileHandleForReading.fileDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "pilotboat.process.read"))
            group.enter()
            source.setEventHandler { [self] in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    lock.withLock { if isOut { outData.append(buffer, count: n) } else { errData.append(buffer, count: n) } }
                } else if n == 0 || errno != EINTR {
                    source.cancel()
                }
            }
            source.setCancelHandler { withExtendedLifetime(pipe) { group.leave() } }
            source.resume()
            return source
        }
        if let stdin {
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        let pid = process.processIdentifier
        let term = DispatchWorkItem { [self] in
            lock.withLock { timedOut = true }
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: term)
        process.waitUntilExit()
        if group.wait(timeout: deadline) == .timedOut, group.wait(timeout: .now() + 5) == .timedOut {
            lock.withLock { timedOut = true }
            sources.forEach { $0.cancel() }
        }
        term.cancel()

        return lock.withLock {
            CommandResult(exitCode: process.terminationStatus, stdout: outData, stderr: errData,
                          timedOut: timedOut, duration: Date().timeIntervalSince(start))
        }
    }
}
