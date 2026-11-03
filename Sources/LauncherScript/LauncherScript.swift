import Core
import Foundation
import ProcessKit

public enum ScriptLauncherError: Error, Equatable, Sendable {
    case missingExecutable
    case failed(exitCode: Int32, stderrTail: String)
    case timedOut
    case invalidOutput(String)
}

public final class ScriptLauncher: Launcher, @unchecked Sendable {
    public static let typeID = "script"
    private let runner: any CommandRunner
    private let lock = NSLock()
    private var known: [String: LauncherCapabilities] = [:]

    public init(runner: any CommandRunner) { self.runner = runner }

    /// Union of the capabilities of every executable queried so far; empty until `capabilities(executable:)` has run.
    public var capabilities: LauncherCapabilities {
        lock.withLock { known.values.reduce([]) { $0.union($1) } }
    }

    public func capabilities(executable: String) async -> LauncherCapabilities {
        if let c = lock.withLock({ known[executable] }) { return c }
        struct Raw: Decodable { var reuseWorkspace: Bool; var sendToSession: Bool }
        guard let r = try? await runner.run(Command(executable, ["capabilities"], timeout: 10)), r.succeeded,
              let raw = try? JSONDecoder().decode(Raw.self, from: r.stdout) else { return [] }
        var c: LauncherCapabilities = []
        if raw.reuseWorkspace { c.insert(.reuseWorkspace) }
        if raw.sendToSession { c.insert(.sendToSession) }
        lock.withLock { known[executable] = c }
        return c
    }

    public func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        let (exe, stdin) = try payload(request)
        let r = try await runner.run(Command(exe, ["launch"], environment: ["PILOTBOAT_RUN_ID": request.runId.uuidString], stdin: stdin, timeout: 120))
        if r.timedOut { throw ScriptLauncherError.timedOut }
        guard r.exitCode == 0 else { throw ScriptLauncherError.failed(exitCode: r.exitCode, stderrTail: r.errorTail) }
        do { return try JSONDecoder().decode(LaunchResult.self, from: r.stdout) }
        catch { throw ScriptLauncherError.invalidOutput(String(r.stdoutText.prefix(200))) }
    }

    public func describe(_ request: LaunchRequest) async -> String {
        var req = request
        req.prompt = String(req.prompt.prefix(200))
        guard let (exe, data) = try? payload(req) else { return "script launcher: missing executable setting" }
        return "\(exe) launch\n" + String(decoding: data, as: UTF8.self)
    }

    public func diagnose(settings: JSONValue) async -> [DiagnosticItem] {
        guard let exe = Self.executable(settings) else {
            return [DiagnosticItem(level: .error, title: "Script launcher", detail: "missing executable setting")]
        }
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            return [DiagnosticItem(level: .error, title: "Script launcher", detail: "\(exe) is missing or not executable")]
        }
        do {
            let r = try await runner.run(Command(exe, ["diagnose"], timeout: 30))
            let line = r.stdoutText.split(whereSeparator: \.isNewline).first.map(String.init)
            return [DiagnosticItem(level: r.succeeded ? .ok : .error, title: "Script launcher", detail: line ?? (r.succeeded ? exe : r.errorTail))]
        } catch {
            return [DiagnosticItem(level: .error, title: "Script launcher", detail: "\(error)")]
        }
    }

    public func open(_ workspaceRef: String, settings: JSONValue) async throws {
        guard let executable = Self.executable(settings) else { throw ScriptLauncherError.missingExecutable }
        let r = try await runner.run(Command(executable, ["open", workspaceRef], timeout: 30))
        if r.timedOut { throw ScriptLauncherError.timedOut }
        guard r.exitCode == 0 else { throw ScriptLauncherError.failed(exitCode: r.exitCode, stderrTail: r.errorTail) }
    }

    private static func executable(_ settings: JSONValue) -> String? {
        guard case .string(let exe)? = settings["executable"], !exe.isEmpty else { return nil }
        return exe
    }

    private func payload(_ request: LaunchRequest) throws -> (String, Data) {
        guard let exe = Self.executable(request.launcherSettings) else { throw ScriptLauncherError.missingExecutable }
        var req = request
        if case .string(let p)? = request.launcherSettings["localPath"], req.repository.launcherBinding == nil {
            req.repository.launcherBinding = p
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return (exe, try enc.encode(req))
    }
}
