import Foundation
import os

public struct ProcessRunner: CommandRunner {
    public let searchPath: [String]
    private static let logger = Logger(subsystem: "io.github.cure-tmk.pilotboat", category: "process")

    public init(searchPath: [String]) { self.searchPath = searchPath }

    public func run(_ command: Command) async throws -> CommandResult {
        guard let path = PathResolver.find(command.executable, in: searchPath) else {
            throw CommandError.executableNotFound(command.executable)
        }
        var env = ["PATH": searchPath.joined(separator: ":"), "HOME": NSHomeDirectory()]
        env.merge(command.environment ?? [:]) { $1 }
        let job = Job(path: path, command: command, environment: env)
        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
            DispatchQueue.global().async { cont.resume(with: Result { try job.execute() }) }
        }
        let args = command.arguments.map { String($0.prefix(200)) }.joined(separator: " ")
        Self.logger.info("\(path, privacy: .public) \(args, privacy: .public) exit=\(result.exitCode) duration=\(result.duration)s timedOut=\(result.timedOut)")
        return result
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

        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                self.lock.withLock { if isOut { self.outData = data } else { self.errData = data } }
                group.leave()
            }
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
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: term)
        process.waitUntilExit()
        term.cancel()
        group.wait()

        return lock.withLock {
            CommandResult(exitCode: process.terminationStatus, stdout: outData, stderr: errData,
                          timedOut: timedOut, duration: Date().timeIntervalSince(start))
        }
    }
}
