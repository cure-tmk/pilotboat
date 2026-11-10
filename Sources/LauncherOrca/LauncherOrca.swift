import Core
import Foundation
import os
import ProcessKit

public struct OrcaSettings: Codable, Hashable, Sendable {
    public var orcaPath: String?
    public var agent: String
    public var model: String?
    public var effort: String?
    public var setupForReview: String
    public var setupForOwnPR: String
    public var activate: Bool

    public init(orcaPath: String? = nil, agent: String, model: String? = nil, effort: String? = nil, setupForReview: String = "skip", setupForOwnPR: String = "inherit", activate: Bool = false) {
        self.orcaPath = orcaPath; self.agent = agent; self.model = model; self.effort = effort
        self.setupForReview = setupForReview; self.setupForOwnPR = setupForOwnPR; self.activate = activate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orcaPath = try c.decodeIfPresent(String.self, forKey: .orcaPath)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        setupForReview = try c.decodeIfPresent(String.self, forKey: .setupForReview) ?? "skip"
        setupForOwnPR = try c.decodeIfPresent(String.self, forKey: .setupForOwnPR) ?? "inherit"
        activate = try c.decodeIfPresent(Bool.self, forKey: .activate) ?? false
    }

    var executable: String { orcaPath ?? "orca" }
    var modelArgs: [String] { (model.map { ["--model", $0] } ?? []) + (effort.map { ["--effort", $0] } ?? []) }
}

public struct OrcaRepo: Hashable, Sendable {
    public var id: String
    public var path: String
    public var displayName: String
    public var canonicalKey: String?
}

public enum OrcaLauncherError: LocalizedError, Equatable {
    case unsupportedSubject
    case notBound(String)
    case agentNotConfigured
    case invalidSettings(String)
    case repoNotFound(String)
    case headCheckedOutInMainWorktree(String)
    case branchMismatch(expected: String, actual: String)
    case diverged(String)
    case chatSurface
    case promptNotHanded(String)
    case sendNotAccepted
    case notRunning
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSubject: String(localized: "The Orca launcher only supports pull requests.")
        case .notBound(let repo): String(localized: "\(repo) is not bound to an Orca repository. Bind it in Settings → Repositories.")
        case .agentNotConfigured: String(localized: "No agent is configured for the Orca launcher.")
        case .invalidSettings(let detail): String(localized: "Invalid Orca launcher settings: \(detail)")
        case .repoNotFound(let id): String(localized: "Orca repository \(id) was not found. Re-bind the repository.")
        case .headCheckedOutInMainWorktree(let branch): String(localized: "The head branch \(branch) is checked out in the main working directory, so no agent was started there.")
        case .branchMismatch(let expected, let actual): String(localized: "Orca created branch \(actual) instead of \(expected); the agent's commits would not reach the pull request.")
        case .diverged(let branch): String(localized: "The local branch \(branch) and the pull request head have diverged.")
        case .chatSurface: String(localized: "Orca started the agent as a chat instead of a terminal.")
        case .promptNotHanded(let outcome): String(localized: "Orca did not hand the prompt to the agent (\(outcome)).")
        case .sendNotAccepted: String(localized: "The running agent did not accept the prompt.")
        case .notRunning: String(localized: "Orca is not running.")
        case .commandFailed(let message): message
        }
    }
}

public struct OrcaRetryableError: RetryableLaunchError, LocalizedError, Equatable {
    public var retryToken: String
    public var message: String
    public var errorDescription: String? { message }
}

public struct OrcaLauncher: Launcher {
    public static let typeID = "orca"
    public let capabilities: LauncherCapabilities = [.reuseWorkspace, .sendToSession]
    private static let logger = Logger(subsystem: "io.github.cure-tmk.pilotboat", category: "orca")

    let runner: any CommandRunner
    let settingsOverride: OrcaSettings?
    let sleep: @Sendable (Duration) async -> Void

    public init(runner: any CommandRunner, settingsOverride: OrcaSettings? = nil, sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.runner = runner; self.settingsOverride = settingsOverride; self.sleep = sleep
    }

    private struct Retry { var kind: String; var id: String }
    private struct Worktree { var id: String; var path: String; var branch: String; var head: String; var isMain: Bool }

    public func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        guard let pr = request.subject.pullRequest else { throw OrcaLauncherError.unsupportedSubject }
        let s = try settings(request.launcherSettings)
        guard !s.agent.isEmpty else { throw OrcaLauncherError.agentNotConfigured }
        guard let repoId = request.repository.launcherBinding else { throw OrcaLauncherError.notBound(request.repository.fullName) }
        let retry = request.retryToken.flatMap { t -> Retry? in
            guard let i = t.firstIndex(of: ":") else { return nil }
            return Retry(kind: String(t[..<i]), id: String(t[t.index(after: i)...]))
        }
        switch request.workspacePolicy {
        case .alwaysNew: return try await alwaysNew(pr, s, repoId, request.prompt, retry)
        case .reuseOrCreate: return try await reuseOrCreate(pr, s, repoId, request, retry)
        case .reusePrevious: return try await reusePrevious(pr, s, repoId, request, retry)
        }
    }

    private func alwaysNew(_ pr: PullRequestRef, _ s: OrcaSettings, _ repoId: String, _ prompt: String, _ retry: Retry?) async throws -> LaunchResult {
        let path = try await repoPath(s, repoId)
        try await git(["-C", path, "fetch", "origin", pr.headRef])
        let result = try await orca(s, ["worktree", "create", "--repo", "id:\(repoId)", "--name", "pr-\(pr.number)-review", "--base-branch", pr.headSHA, "--pr", "\(pr.number)", "--no-parent", "--agent", s.agent, "--surface", "terminal", "--prompt", prompt, "--setup", s.setupForReview] + s.modelArgs + (s.activate ? ["--activate"] : []) + launchRetry(retry))
        let launch = result["launch"] ?? .null
        let handle = try checkLaunch(launch)
        guard let worktreeId = launch["worktreeId"]?.string ?? result["worktree"]?["id"]?.string else { throw OrcaLauncherError.commandFailed("orca worktree create returned no worktree id") }
        return LaunchResult(workspaceRef: worktreeId, terminalHandle: handle)
    }

    private func reuseOrCreate(_ pr: PullRequestRef, _ s: OrcaSettings, _ repoId: String, _ request: LaunchRequest, _ retry: Retry?) async throws -> LaunchResult {
        let branch = "refs/heads/\(pr.headRef)"
        if let wt = try await worktrees(s).first(where: { $0.repoId == repoId && $0.wt.branch == branch })?.wt {
            if wt.isMain { throw OrcaLauncherError.headCheckedOutInMainWorktree(pr.headRef) }
            return try await continueIn(wt.id, s, request, retry)
        }

        let path = try await repoPath(s, repoId)
        try await git(["-C", path, "fetch", "origin", pr.headRef])
        let created = try await orca(s, ["worktree", "create", "--repo", "id:\(repoId)", "--name", "pr-\(pr.number)", "--branch", pr.headRef, "--base-branch", "origin/\(pr.headRef)", "--pr", "\(pr.number)", "--no-parent", "--setup", s.setupForOwnPR] + (s.activate ? ["--activate"] : []))
        guard let id = created["worktree"]?["id"]?.string, let wt = try await worktrees(s).first(where: { $0.wt.id == id })?.wt else {
            throw OrcaLauncherError.commandFailed("orca worktree create returned no worktree id")
        }
        guard wt.branch == branch else { throw OrcaLauncherError.branchMismatch(expected: branch, actual: wt.branch) }
        if try await runner.run(Command("git", ["-C", wt.path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])).succeeded == false {
            try await git(["-C", wt.path, "branch", "--set-upstream-to=origin/\(pr.headRef)"])
        }
        if wt.head != pr.headSHA {
            if try await isAncestor(wt.path, wt.head, pr.headSHA) {
                try await git(["-C", wt.path, "merge", "--ff-only", "origin/\(pr.headRef)"])
            } else if try await !isAncestor(wt.path, pr.headSHA, wt.head) {
                throw OrcaLauncherError.diverged(pr.headRef)
            }
        }
        return LaunchResult(workspaceRef: wt.id, terminalHandle: try await agentLaunch(s, wt.id, request.prompt, retry))
    }

    private func reusePrevious(_ pr: PullRequestRef, _ s: OrcaSettings, _ repoId: String, _ request: LaunchRequest, _ retry: Retry?) async throws -> LaunchResult {
        if let ref = request.previousWorkspaceRef,
           let wt = try await worktrees(s).first(where: { $0.repoId == repoId && $0.wt.id == ref })?.wt, !wt.isMain {
            try await git(["-C", wt.path, "fetch", "origin", pr.headRef])
            let merge = try await runner.run(Command("git", ["-C", wt.path, "merge", "--ff-only", pr.headSHA]))
            if merge.succeeded { return try await continueIn(wt.id, s, request, retry) }
            Self.logger.notice("Fast-forward of \(wt.path, privacy: .public) to \(pr.headSHA, privacy: .public) failed, starting in a new worktree: \(merge.errorTail, privacy: .public)")
        }
        return try await alwaysNew(pr, s, repoId, request.prompt, retry)
    }

    private func continueIn(_ worktreeId: String, _ s: OrcaSettings, _ request: LaunchRequest, _ retry: Retry?) async throws -> LaunchResult {
        // A replayed --retry-launch must not be turned into a send: the lost launch may have started the agent.
        if retry?.kind != "launch", let handle = try await runningAgent(s, worktreeId, preferred: request.previousTerminalHandle) {
            let send = try await orca(s, ["terminal", "send", "--terminal", handle, "--text", request.prompt, "--enter", "--wait-submit", "10"] + (retry?.kind == "request" ? ["--retry-request", retry!.id] : []))["send"]
            let stages = send?["prompt"]?["stages"]?.array?.compactMap(\.string) ?? []
            guard send?["accepted"]?.bool == true, stages.contains("input_accepted") else { throw OrcaLauncherError.sendNotAccepted }
            return LaunchResult(workspaceRef: worktreeId, terminalHandle: handle, reusedWorkspace: true, sentToExistingSession: true,
                                retryToken: send?["prompt"]?["requestId"]?.string.map { "request:\($0)" })
        }
        return LaunchResult(workspaceRef: worktreeId, terminalHandle: try await agentLaunch(s, worktreeId, request.prompt, retry), reusedWorkspace: true)
    }

    private func agentLaunch(_ s: OrcaSettings, _ worktreeId: String, _ prompt: String, _ retry: Retry?) async throws -> String {
        let result = try await orca(s, ["agent", "launch", "--worktree", "id:\(worktreeId)", "--agent", s.agent, "--surface", "terminal", "--prompt", prompt] + s.modelArgs + (s.activate ? ["--focus"] : []) + launchRetry(retry))
        return try checkLaunch(result)
    }

    private func checkLaunch(_ launch: JSONValue) throws -> String {
        guard launch["outcome"]?["kind"]?.string == "terminal", let handle = launch["outcome"]?["handle"]?.string else { throw OrcaLauncherError.chatSurface }
        let outcome = launch["prompt"]?["outcome"]?.string ?? "none"
        guard outcome == "handed-to-terminal" else { throw OrcaLauncherError.promptNotHanded(outcome) }
        return handle
    }

    private func launchRetry(_ retry: Retry?) -> [String] {
        retry?.kind == "launch" ? ["--retry-launch", retry!.id] : []
    }

    /// Agent identity lingers for a few seconds after the agent exits, so require two matches 3 s apart
    /// before typing into the terminal; otherwise the prompt could run as a shell command.
    private func runningAgent(_ s: OrcaSettings, _ worktreeId: String, preferred: String?) async throws -> String? {
        func live() async throws -> [String] {
            try await orca(s, ["terminal", "list", "--worktree", "id:\(worktreeId)"])["terminals"]?.array?.filter {
                $0["agentIdentity"]?.string == s.agent && $0["connected"]?.bool == true && $0["writable"]?.bool == true && $0["orphaned"]?.bool != true
            }.compactMap { $0["handle"]?.string } ?? []
        }
        let first = try await live()
        guard let handle = first.first(where: { $0 == preferred }) ?? first.first else { return nil }
        await sleep(.seconds(3))
        return try await live().contains(handle) ? handle : nil
    }

    private func isAncestor(_ path: String, _ a: String, _ b: String) async throws -> Bool {
        let r = try await runner.run(Command("git", ["-C", path, "merge-base", "--is-ancestor", a, b]))
        if r.exitCode == 0 { return true }
        if r.exitCode == 1 { return false }
        throw OrcaLauncherError.commandFailed(r.errorTail)
    }

    private func git(_ args: [String]) async throws {
        let r = try await runner.run(Command("git", args))
        guard r.succeeded else { throw OrcaLauncherError.commandFailed(r.errorTail) }
    }

    private func worktrees(_ s: OrcaSettings) async throws -> [(repoId: String, wt: Worktree)] {
        try await orca(s, ["worktree", "list"])["worktrees"]?.array?.compactMap { w in
            guard let id = w["id"]?.string, let repoId = w["repoId"]?.string, let path = w["path"]?.string else { return nil }
            return (repoId, Worktree(id: id, path: path, branch: w["branch"]?.string ?? "", head: w["head"]?.string ?? "", isMain: w["isMainWorktree"]?.bool ?? false))
        } ?? []
    }

    private func repoPath(_ s: OrcaSettings, _ repoId: String) async throws -> String {
        guard let path = try await repos(s).first(where: { $0.id == repoId })?.path else { throw OrcaLauncherError.repoNotFound(repoId) }
        return path
    }

    private func repos(_ s: OrcaSettings) async throws -> [OrcaRepo] {
        try await orca(s, ["repo", "list"])["repos"]?.array?.compactMap { r in
            guard let id = r["id"]?.string, let path = r["path"]?.string else { return nil }
            return OrcaRepo(id: id, path: path, displayName: r["displayName"]?.string ?? path, canonicalKey: r["gitRemoteIdentity"]?["canonicalKey"]?.string)
        } ?? []
    }

    @discardableResult
    private func orca(_ s: OrcaSettings, _ args: [String], reopened: Bool = false) async throws -> JSONValue {
        let r = try await runner.run(Command(s.executable, args + ["--json"]))
        let json = (try? JSONDecoder().decode(JSONValue.self, from: r.stdout)) ?? (try? JSONDecoder().decode(JSONValue.self, from: r.stderr))
        if json?["ok"]?.bool == true { return json?["result"] ?? .null }
        let error = json?["error"]
        if error?["code"]?.string == "runtime_unavailable" {
            if reopened { throw OrcaLauncherError.notRunning }
            try await orca(s, ["open"], reopened: true)
            return try await orca(s, args, reopened: true)
        }
        let text = r.stdoutText + r.stderrText
        let steps = error?["data"]?["nextSteps"]?.array?.compactMap(\.string) ?? []
        let message = ([error?["message"]?.string ?? r.errorTail] + steps).joined(separator: "\n")
        if let m = text.firstMatch(of: /--retry-(launch|request)["\s,]+([A-Za-z0-9_-]+)/) {
            throw OrcaRetryableError(retryToken: "\(m.1):\(m.2)", message: message)
        }
        throw OrcaLauncherError.commandFailed(message)
    }

    private func settings(_ json: JSONValue) throws -> OrcaSettings {
        if let settingsOverride { return settingsOverride }
        do { return try JSONDecoder().decode(OrcaSettings.self, from: JSONEncoder().encode(json)) }
        catch { throw OrcaLauncherError.invalidSettings(error.localizedDescription) }
    }

    public func listRepos() async throws -> [OrcaRepo] {
        try await repos(settingsOverride ?? OrcaSettings(agent: ""))
    }

    public func describe(_ request: LaunchRequest) async -> String {
        guard let pr = request.subject.pullRequest, let s = try? settings(request.launcherSettings) else { return "orca: invalid request" }
        let repo = "id:\(request.repository.launcherBinding ?? "<unbound>")"
        let prompt = request.prompt.count > 200 ? String(request.prompt.prefix(200)) + "…" : request.prompt
        let agent = ["--agent", s.agent, "--surface", "terminal", "--prompt", prompt] + s.modelArgs
        let o = s.executable
        let send = [o, "terminal", "send", "--terminal", "<handle>", "--text", prompt, "--enter", "--wait-submit", "10", "--json"]
        let fresh = [["git", "-C", "<repo path>", "fetch", "origin", pr.headRef],
                     [o, "worktree", "create", "--repo", repo, "--name", "pr-\(pr.number)-review", "--base-branch", pr.headSHA, "--pr", "\(pr.number)", "--no-parent"] + agent + ["--setup", s.setupForReview, "--json"]]
        let lines: [[String]]
        switch request.workspacePolicy {
        case .alwaysNew:
            lines = fresh
        case .reusePrevious:
            let previous = request.previousWorkspaceRef ?? "<none>"
            lines = [[o, "worktree", "list", "--json"],
                     ["# if the previous worktree \(previous) still exists:"],
                     ["git", "-C", "<worktree path>", "fetch", "origin", pr.headRef],
                     ["git", "-C", "<worktree path>", "merge", "--ff-only", pr.headSHA],
                     ["#   then, if an agent is running:"], send,
                     ["#   else:"], [o, "agent", "launch", "--worktree", "id:\(previous)"] + agent + ["--json"],
                     ["# otherwise, or when the fast-forward fails:"]] + fresh
        case .reuseOrCreate:
            lines = [[o, "worktree", "list", "--json"],
                     ["# if refs/heads/\(pr.headRef) exists and an agent is running:"],
                     send,
                     ["# otherwise, creating the worktree first when missing:"],
                     ["git", "-C", "<repo path>", "fetch", "origin", pr.headRef],
                     [o, "worktree", "create", "--repo", repo, "--name", "pr-\(pr.number)", "--branch", pr.headRef, "--base-branch", "origin/\(pr.headRef)", "--pr", "\(pr.number)", "--no-parent", "--setup", s.setupForOwnPR, "--json"],
                     [o, "agent", "launch", "--worktree", "id:<worktree id>"] + agent + ["--json"]]
        }
        return lines.map { $0.joined(separator: " ") }.joined(separator: "\n")
    }

    public func diagnose(settings json: JSONValue) async -> [DiagnosticItem] {
        let s = (try? settings(json)) ?? OrcaSettings(agent: "")
        var items: [DiagnosticItem] = []
        if let r = try? await runner.run(Command(s.executable, ["--version"])), r.succeeded {
            items.append(DiagnosticItem(level: .ok, title: String(localized: "orca found"), detail: r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else {
            items.append(DiagnosticItem(level: .error, title: String(localized: "orca not found"), detail: s.executable))
        }
        let status = try? await orca(s, ["status"], reopened: true)
        let running = status?["app"]?["running"]?.bool == true && status?["runtime"]?["reachable"]?.bool == true
        items.append(DiagnosticItem(level: running ? .ok : .warning, title: running ? String(localized: "Orca is running") : String(localized: "Orca is not running")))
        items.append(s.agent.isEmpty
            ? DiagnosticItem(level: .warning, title: String(localized: "No agent configured"))
            : DiagnosticItem(level: .ok, title: String(localized: "Agent: \(s.agent)")))
        return items
    }

    public func open(_ workspaceRef: String, settings json: JSONValue) async throws {
        let s = try settings(json)
        if let handle = try await orca(s, ["terminal", "list", "--worktree", "id:\(workspaceRef)"])["terminals"]?.array?.first?["handle"]?.string {
            try await orca(s, ["terminal", "switch", "--terminal", handle])
        } else {
            try await orca(s, ["open"])
        }
    }
}

private extension JSONValue {
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
}
