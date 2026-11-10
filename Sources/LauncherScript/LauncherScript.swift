import Core
import Foundation
import os
import ProcessKit

public enum ScriptLauncherError: LocalizedError, Equatable, Sendable {
    case missingExecutable
    case failed(exitCode: Int32, stderrTail: String)
    case timedOut
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable: "The script launcher has no executable configured."
        case .failed(let code, let tail): "The launcher script exited with code \(code).\(tail.isEmpty ? "" : "\n\(tail)")"
        case .timedOut: "The launcher script timed out."
        case .invalidOutput(let output): "The launcher script printed invalid JSON: \(output)"
        }
    }
}

public struct ScriptSettings: Codable, Sendable {
    public var executable: String?
    public var localPath: String?

    public init(executable: String? = nil, localPath: String? = nil) { self.executable = executable; self.localPath = localPath }

    /// Settings that do not decode are treated as empty, which surfaces as a missing executable.
    public init(json: JSONValue) { self = (try? json.decode(Self.self)) ?? Self() }

    public func json() -> JSONValue { (try? JSONValue(encoding: self)) ?? .object([:]) }

    var resolvedExecutable: String? { executable.flatMap { $0.isEmpty ? nil : $0 } }
}

/// Version 1 of the JSON a script receives on stdin for `launch`. Field names are frozen; see contrib/launchers/README.md.
public struct ScriptLaunchRequestV1: Codable, Sendable {
    public struct Repository: Codable, Sendable {
        public var host: String
        public var fullName: String
        public var launcherBinding: String?
    }

    public struct PullRequest: Codable, Sendable {
        public var host: String
        public var repo: String
        public var number: Int
        public var url: URL
        public var title: String
        public var headRef: String
        public var headSHA: String
        public var baseRef: String
        public var isDraft: Bool
        public var isCrossRepository: Bool
        public var labels: [String]
        public var author: String
        public var state: String
    }

    public struct Subject: Codable, Sendable {
        public var type: String
        public var pullRequest: PullRequest?
    }

    public var version = 1
    public var runId: UUID
    public var subject: Subject
    public var repository: Repository
    public var workspacePolicy: String
    public var prompt: String
    public var previousWorkspaceRef: String?
    public var previousTerminalHandle: String?
    public var launcherSettings: JSONValue
    public var retryToken: String?

    /// `repository.launcherBinding` falls back to `launcherSettings.localPath`, so a script can always read the
    /// local checkout from the binding; a per-repository binding wins over the launcher-wide `localPath`.
    public init(_ request: LaunchRequest) {
        let pr = request.subject.pullRequest
        runId = request.runId
        subject = Subject(type: "pullRequest", pullRequest: pr.map {
            PullRequest(host: $0.host, repo: $0.repo, number: $0.number, url: $0.url, title: $0.title, headRef: $0.headRef,
                        headSHA: $0.headSHA, baseRef: $0.baseRef, isDraft: $0.isDraft, isCrossRepository: $0.isCrossRepository,
                        labels: $0.labels, author: $0.author, state: $0.state.rawValue)
        })
        repository = Repository(host: request.repository.host, fullName: request.repository.fullName,
                                launcherBinding: request.repository.launcherBinding ?? ScriptSettings(json: request.launcherSettings).localPath)
        workspacePolicy = request.workspacePolicy.rawValue
        prompt = request.prompt
        previousWorkspaceRef = request.previousWorkspaceRef
        previousTerminalHandle = request.previousTerminalHandle
        launcherSettings = request.launcherSettings
        retryToken = request.retryToken
    }
}

/// Version 1 of the JSON a script prints on stdout for `launch`; only `workspaceRef` is required.
public struct ScriptLaunchResultV1: Codable, Sendable {
    public var workspaceRef: String
    public var terminalHandle: String?
    public var reusedWorkspace: Bool?
    public var sentToExistingSession: Bool?
    public var retryToken: String?

    public var launchResult: LaunchResult {
        LaunchResult(workspaceRef: workspaceRef, terminalHandle: terminalHandle, reusedWorkspace: reusedWorkspace ?? false,
                     sentToExistingSession: sentToExistingSession ?? false, retryToken: retryToken)
    }
}

public final class ScriptLauncher: Launcher, Sendable {
    public static let typeID = "script"
    private let runner: any CommandRunner
    private let known = OSAllocatedUnfairLock<[String: LauncherCapabilities]>(initialState: [:])

    public init(runner: any CommandRunner) { self.runner = runner }

    public func capabilities(settings: JSONValue) async -> LauncherCapabilities {
        guard let exe = ScriptSettings(json: settings).resolvedExecutable else { return [] }
        return await capabilities(executable: exe)
    }

    /// Cached per executable for the launcher's lifetime; a failed query is not cached so the next call asks again.
    public func capabilities(executable: String) async -> LauncherCapabilities {
        if let c = known.withLock({ $0[executable] }) { return c }
        struct Raw: Decodable { var reuseWorkspace: Bool; var sendToSession: Bool }
        guard let r = try? await runner.run(Command(executable, ["capabilities"], timeout: 10)), r.succeeded,
              let raw = try? JSONDecoder().decode(Raw.self, from: r.stdout) else { return [] }
        var c: LauncherCapabilities = []
        if raw.reuseWorkspace { c.insert(.reuseWorkspace) }
        if raw.sendToSession { c.insert(.sendToSession) }
        let found = c
        known.withLock { $0[executable] = found }
        return found
    }

    public func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        let (exe, stdin) = try payload(request)
        let r = try await runner.run(Command(exe, ["launch"], environment: ["PILOTBOAT_RUN_ID": request.runId.uuidString], stdin: stdin, timeout: 120))
        if r.timedOut { throw ScriptLauncherError.timedOut }
        guard r.exitCode == 0 else { throw ScriptLauncherError.failed(exitCode: r.exitCode, stderrTail: r.errorTail) }
        do { return try JSONDecoder().decode(ScriptLaunchResultV1.self, from: r.stdout).launchResult }
        catch { throw ScriptLauncherError.invalidOutput(String(r.stdoutText.prefix(200))) }
    }

    public func describe(_ request: LaunchRequest) async -> String {
        var req = request
        req.prompt = String(req.prompt.prefix(200))
        guard let (exe, data) = try? payload(req) else { return "script launcher: missing executable setting" }
        return "\(exe) launch\n" + String(decoding: data, as: UTF8.self)
    }

    public func diagnose(settings: JSONValue) async -> [DiagnosticItem] {
        guard let exe = ScriptSettings(json: settings).resolvedExecutable else {
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
        guard let executable = ScriptSettings(json: settings).resolvedExecutable else { throw ScriptLauncherError.missingExecutable }
        let r = try await runner.run(Command(executable, ["open", workspaceRef], timeout: 30))
        if r.timedOut { throw ScriptLauncherError.timedOut }
        guard r.exitCode == 0 else { throw ScriptLauncherError.failed(exitCode: r.exitCode, stderrTail: r.errorTail) }
    }

    private func payload(_ request: LaunchRequest) throws -> (String, Data) {
        guard let exe = ScriptSettings(json: request.launcherSettings).resolvedExecutable else { throw ScriptLauncherError.missingExecutable }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (exe, try enc.encode(ScriptLaunchRequestV1(request)))
    }
}
