import Core
import Foundation
import ProcessKit

enum RetryToken: Equatable, Sendable {
    case launch(String)
    case request(String)

    init?(stored: String) {
        guard let i = stored.firstIndex(of: ":") else { return nil }
        let id = String(stored[stored.index(after: i)...])
        switch stored[..<i] {
        case "launch": self = .launch(id)
        case "request": self = .request(id)
        default: return nil
        }
    }

    var stored: String {
        switch self {
        case .launch(let id): "launch:\(id)"
        case .request(let id): "request:\(id)"
        }
    }
}

struct OrcaCLI: Sendable {
    let runner: any CommandRunner
    let executable: String

    struct Worktree: Decodable, Equatable {
        var id: String
        var repoId: String
        var path: String
        var branch: String?
        var head: String?
        var isMainWorktree: Bool?
        var isMain: Bool { isMainWorktree == true }
    }

    struct Terminal: Decodable {
        var handle: String
        var agentIdentity: String?
        var connected: Bool?
        var writable: Bool?
        var orphaned: Bool?
    }

    struct AgentLaunch: Decodable {
        struct Outcome: Decodable { var kind: String?; var handle: String? }
        struct Prompt: Decodable { var outcome: String? }
        var worktreeId: String?
        var outcome: Outcome?
        var prompt: Prompt?
    }

    struct WorktreeCreated: Decodable {
        struct Ref: Decodable { var id: String? }
        var worktree: Ref?
        var launch: AgentLaunch?
    }

    struct Send: Decodable {
        struct Prompt: Decodable { var requestId: String?; var stages: [String]? }
        var accepted: Bool?
        var prompt: Prompt?
    }

    struct Status: Decodable {
        struct App: Decodable { var running: Bool? }
        struct Runtime: Decodable { var reachable: Bool? }
        var app: App?
        var runtime: Runtime?
    }

    private struct Repo: Decodable {
        struct Identity: Decodable { var canonicalKey: String? }
        var id: String
        var path: String
        var displayName: String?
        var gitRemoteIdentity: Identity?
    }

    func repos() async throws -> [OrcaRepo] {
        rows(try await call(["repo", "list"])["repos"], Repo.self).map {
            OrcaRepo(id: $0.id, path: $0.path, displayName: $0.displayName ?? $0.path, canonicalKey: $0.gitRemoteIdentity?.canonicalKey)
        }
    }

    func worktrees() async throws -> [Worktree] { rows(try await call(Self.worktreeList)["worktrees"], Worktree.self) }

    func terminals(worktree id: String) async throws -> [Terminal] { rows(try await call(Self.terminalList(worktree: id))["terminals"], Terminal.self) }

    func createWorktree(_ args: [String]) async throws -> WorktreeCreated { try decode(try await call(args), args) }

    func launchAgent(_ args: [String]) async throws -> AgentLaunch { try decode(try await call(args), args) }

    func send(_ args: [String]) async throws -> Send {
        guard let send = try await call(args)["send"], send != .null else { throw OrcaLauncherError.sendNotAccepted }
        return try decode(send, args)
    }

    /// Never opens Orca, so diagnostics stay side-effect free.
    func status() async throws -> Status { try decode(try await call(["status"], reopen: false), ["status"]) }

    func open() async throws { _ = try await call(["open"]) }

    func switchTerminal(_ handle: String) async throws { _ = try await call(["terminal", "switch", "--terminal", handle]) }

    func call(_ args: [String]) async throws -> JSONValue { try await call(args, reopen: true) }

    private func call(_ args: [String], reopen: Bool) async throws -> JSONValue {
        let r = try await runner.run(Command(executable, args + ["--json"]))
        let json = (try? JSONDecoder().decode(JSONValue.self, from: r.stdout)) ?? (try? JSONDecoder().decode(JSONValue.self, from: r.stderr))
        if json?["ok"]?.bool == true { return json?["result"] ?? .null }
        let error = json?["error"]
        if error?["code"]?.string == "runtime_unavailable" {
            guard reopen else { throw OrcaLauncherError.notRunning }
            do { _ = try await call(["open"], reopen: false) } catch { throw OrcaLauncherError.notRunning }
            return try await call(args, reopen: false)
        }
        let steps = error?["data"]?["nextSteps"]?.array?.compactMap(\.string) ?? []
        let message = ([error?["message"]?.string ?? r.errorTail] + steps).joined(separator: "\n")
        if let m = (r.stdoutText + r.stderrText).firstMatch(of: /--retry-(launch|request)["\s,]+([A-Za-z0-9_-]+)/),
           let token = RetryToken(stored: "\(m.1):\(m.2)") {
            throw OrcaRetryableError(retryToken: token.stored, message: message)
        }
        throw OrcaLauncherError.commandFailed(message)
    }

    private func decode<T: Decodable>(_ json: JSONValue, _ args: [String]) throws -> T {
        do { return try json.decode(T.self) }
        catch { throw OrcaLauncherError.commandFailed("orca \(args.prefix(2).joined(separator: " ")) returned unexpected JSON") }
    }

    /// Skips rows that do not decode, so one odd entry (e.g. a folder workspace) cannot fail the whole list.
    private func rows<T: Decodable>(_ json: JSONValue?, _: T.Type) -> [T] {
        json?.array?.compactMap { try? $0.decode(T.self) } ?? []
    }
}

extension OrcaCLI {
    static let worktreeList = ["worktree", "list"]

    static func terminalList(worktree id: String) -> [String] { ["terminal", "list", "--worktree", "id:\(id)"] }

    static func createReviewWorktree(repoId: String, pr: PullRequestRef, prompt: String, settings s: OrcaSettings, retry: RetryToken?) -> [String] {
        ["worktree", "create", "--repo", "id:\(repoId)", "--name", "pr-\(pr.number)-review", "--base-branch", pr.headSHA, "--pr", "\(pr.number)", "--no-parent",
         "--agent", s.agent, "--surface", "terminal", "--prompt", prompt, "--setup", s.setupForReview.rawValue]
            + s.modelArgs + (s.activate ? ["--activate"] : []) + launchRetry(retry)
    }

    static func createBranchWorktree(repoId: String, pr: PullRequestRef, settings s: OrcaSettings) -> [String] {
        ["worktree", "create", "--repo", "id:\(repoId)", "--name", "pr-\(pr.number)", "--branch", pr.headRef, "--base-branch", "origin/\(pr.headRef)",
         "--pr", "\(pr.number)", "--no-parent", "--setup", s.setupForOwnPR.rawValue] + (s.activate ? ["--activate"] : [])
    }

    static func launchAgent(worktree id: String, prompt: String, settings s: OrcaSettings, retry: RetryToken?) -> [String] {
        ["agent", "launch", "--worktree", "id:\(id)", "--agent", s.agent, "--surface", "terminal", "--prompt", prompt]
            + s.modelArgs + (s.activate ? ["--focus"] : []) + launchRetry(retry)
    }

    static func send(terminal handle: String, prompt: String, retry: RetryToken?) -> [String] {
        var args = ["terminal", "send", "--terminal", handle, "--text", prompt, "--enter", "--wait-submit", "10"]
        if case .request(let id) = retry { args += ["--retry-request", id] }
        return args
    }

    private static func launchRetry(_ retry: RetryToken?) -> [String] {
        if case .launch(let id) = retry { ["--retry-launch", id] } else { [] }
    }
}
