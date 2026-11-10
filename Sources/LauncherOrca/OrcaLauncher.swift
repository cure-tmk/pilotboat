import Core
import Foundation
import ProcessKit

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
        case .unsupportedSubject: "The Orca launcher only supports pull requests."
        case .notBound(let repo): "\(repo) is not bound to an Orca repository."
        case .agentNotConfigured: "No agent is configured for the Orca launcher."
        case .invalidSettings(let path): "Invalid Orca launcher settings at \(path)."
        case .repoNotFound(let id): "Orca repository \(id) was not found."
        case .headCheckedOutInMainWorktree(let branch): "The head branch \(branch) is checked out in the main working directory."
        case .branchMismatch(let expected, let actual): "Orca created branch \(actual) instead of \(expected)."
        case .diverged(let branch): "The local branch \(branch) and the pull request head have diverged."
        case .chatSurface: "Orca started the agent as a chat instead of a terminal."
        case .promptNotHanded(let outcome): "Orca did not hand the prompt to the agent (\(outcome))."
        case .sendNotAccepted: "The running agent did not accept the prompt."
        case .notRunning: "Orca is not running."
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
    public func capabilities(settings: JSONValue) async -> LauncherCapabilities { [.reuseWorkspace, .sendToSession] }

    let runner: any CommandRunner
    let settingsOverride: OrcaSettings?
    let sleep: @Sendable (Duration) async -> Void

    public init(runner: any CommandRunner, settingsOverride: OrcaSettings? = nil, sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.runner = runner; self.settingsOverride = settingsOverride; self.sleep = sleep
    }

    public func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        guard let pr = request.subject.pullRequest else { throw OrcaLauncherError.unsupportedSubject }
        let s = try settings(request.launcherSettings)
        guard !s.agent.isEmpty else { throw OrcaLauncherError.agentNotConfigured }
        guard let repoId = request.repository.launcherBinding else { throw OrcaLauncherError.notBound(request.repository.fullName) }
        let flow = Flow(cli: cli(s), git: Git(runner: runner), sleep: sleep, s: s, pr: pr, repoId: repoId, request: request,
                        retry: request.retryToken.flatMap(RetryToken.init(stored:)))
        switch request.workspacePolicy {
        case .alwaysNew: return try await flow.alwaysNew()
        case .reuseOrCreate: return try await flow.reuseOrCreate()
        case .reusePrevious: return try await flow.reusePrevious()
        }
    }

    public func listRepos() async throws -> [OrcaRepo] {
        try await cli(settingsOverride ?? OrcaSettings(agent: "")).repos()
    }

    public func describe(_ request: LaunchRequest) async -> String {
        guard let pr = request.subject.pullRequest, let s = try? settings(request.launcherSettings) else { return "orca: invalid request" }
        let repoId = request.repository.launcherBinding ?? "<unbound>"
        let retry = request.retryToken.flatMap(RetryToken.init(stored:))
        let prompt = request.prompt.count > 200 ? String(request.prompt.prefix(200)) + "…" : request.prompt
        func orca(_ args: [String]) -> [String] { [s.executable] + args + ["--json"] }
        func reuse(_ id: String) -> [[String]] {
            let launch = orca(OrcaCLI.launchAgent(worktree: id, prompt: prompt, settings: s, retry: retry))
            if case .launch = retry { return [launch] }
            return [orca(OrcaCLI.terminalList(worktree: id)),
                    ["#   if an agent is running:"], orca(OrcaCLI.send(terminal: "<handle>", prompt: prompt, retry: retry)),
                    ["#   else:"], launch]
        }
        let fresh = [orca(["repo", "list"]),
                     Git.fetch(path: "<repo-path>", ref: pr.headRef),
                     orca(OrcaCLI.createReviewWorktree(repoId: repoId, pr: pr, prompt: prompt, settings: s, retry: retry))]
        let lines: [[String]]
        switch request.workspacePolicy {
        case .alwaysNew:
            lines = fresh
        case .reusePrevious:
            let previous = request.previousWorkspaceRef ?? "<none>"
            lines = [orca(OrcaCLI.worktreeList),
                     ["# if the previous worktree \(previous) still exists:"],
                     Git.fetch(path: "<worktree-path>", ref: pr.headRef),
                     Git.ffMerge(path: "<worktree-path>", to: pr.headSHA)]
                + reuse(previous)
                + [["# otherwise, or when the fast-forward fails:"]] + fresh
        case .reuseOrCreate:
            let path = "<worktree-path>"
            lines = [orca(OrcaCLI.worktreeList),
                     ["# if refs/heads/\(pr.headRef) is checked out in a worktree:"]]
                + reuse("<worktree-id>")
                + [["# otherwise:"],
                   ["#   if no main worktree is listed:"], orca(["repo", "list"]),
                   Git.fetch(path: "<repo-path>", ref: pr.headRef),
                   orca(OrcaCLI.createBranchWorktree(repoId: repoId, pr: pr, settings: s)),
                   orca(OrcaCLI.worktreeList),
                   Git.upstream(path: path),
                   ["#   if no upstream:"], Git.setUpstream(path: path, ref: pr.headRef),
                   ["#   if behind the pull request head:"], Git.isAncestor(path: path, "<worktree-head>", pr.headSHA),
                   Git.ffMerge(path: path, to: "origin/\(pr.headRef)"),
                   orca(OrcaCLI.launchAgent(worktree: "<worktree-id>", prompt: prompt, settings: s, retry: retry))]
        }
        return lines.map { $0.first?.hasPrefix("#") == true ? $0.joined(separator: " ") : Self.render($0) }.joined(separator: "\n")
    }

    public func diagnose(settings json: JSONValue) async -> [DiagnosticItem] {
        let s = (try? settings(json)) ?? OrcaSettings(agent: "")
        var items: [DiagnosticItem] = []
        if let r = try? await runner.run(Command(s.executable, ["--version"])), r.succeeded {
            items.append(DiagnosticItem(level: .ok, title: "orca found", detail: r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else {
            items.append(DiagnosticItem(level: .error, title: "orca not found", detail: s.executable))
        }
        let status = try? await cli(s).status()
        let running = status?.app?.running == true && status?.runtime?.reachable == true
        items.append(DiagnosticItem(level: running ? .ok : .warning, title: running ? "Orca is running" : "Orca is not running"))
        items.append(s.agent.isEmpty
            ? DiagnosticItem(level: .warning, title: "No agent configured")
            : DiagnosticItem(level: .ok, title: "Agent: \(s.agent)"))
        return items
    }

    public func open(_ workspaceRef: String, settings json: JSONValue) async throws {
        let cli = cli(try settings(json))
        if let handle = try await cli.terminals(worktree: workspaceRef).first?.handle {
            try await cli.switchTerminal(handle)
        } else {
            try await cli.open()
        }
    }

    static func render(_ argv: [String]) -> String {
        argv.map { arg in
            arg.isEmpty || arg.contains(where: { !($0.isLetter || $0.isNumber || "-_./:=@{}<>".contains($0)) })
                ? "'" + arg.replacingOccurrences(of: "'", with: #"'\''"#) + "'" : arg
        }.joined(separator: " ")
    }

    private func cli(_ s: OrcaSettings) -> OrcaCLI { OrcaCLI(runner: runner, executable: s.executable) }

    private func settings(_ json: JSONValue) throws -> OrcaSettings {
        try settingsOverride ?? OrcaSettings(json: json)
    }
}

private struct Flow {
    let cli: OrcaCLI
    let git: Git
    let sleep: @Sendable (Duration) async -> Void
    let s: OrcaSettings
    let pr: PullRequestRef
    let repoId: String
    let request: LaunchRequest
    let retry: RetryToken?

    func alwaysNew() async throws -> LaunchResult {
        guard let path = try await cli.repos().first(where: { $0.id == repoId })?.path else { throw OrcaLauncherError.repoNotFound(repoId) }
        try await git.fetch(path: path, ref: pr.headRef)
        let args = OrcaCLI.createReviewWorktree(repoId: repoId, pr: pr, prompt: request.prompt, settings: s, retry: retry)
        let created = try await cli.createWorktree(args)
        let handle = try Self.handle(created.launch)
        guard let id = created.launch?.worktreeId ?? created.worktree?.id else { throw OrcaLauncherError.commandFailed("orca worktree create returned no worktree id") }
        return LaunchResult(workspaceRef: id, terminalHandle: handle)
    }

    func reuseOrCreate() async throws -> LaunchResult {
        let branch = "refs/heads/\(pr.headRef)"
        let rows = try await cli.worktrees().filter { $0.repoId == repoId }
        if let wt = rows.first(where: { $0.branch == branch }) {
            if wt.isMain { throw OrcaLauncherError.headCheckedOutInMainWorktree(pr.headRef) }
            return try await continueIn(wt.id)
        }

        var repoPath = rows.first(where: \.isMain)?.path
        if repoPath == nil { repoPath = try await cli.repos().first(where: { $0.id == repoId })?.path }
        guard let repoPath else { throw OrcaLauncherError.repoNotFound(repoId) }
        try await git.fetch(path: repoPath, ref: pr.headRef)
        let created = try await cli.createWorktree(OrcaCLI.createBranchWorktree(repoId: repoId, pr: pr, settings: s))
        guard let id = created.worktree?.id, let wt = try await cli.worktrees().first(where: { $0.id == id }) else {
            throw OrcaLauncherError.commandFailed("orca worktree create returned no worktree id")
        }
        guard wt.branch == branch else { throw OrcaLauncherError.branchMismatch(expected: branch, actual: wt.branch ?? "") }
        if try await !git.hasUpstream(path: wt.path) {
            try await git.setUpstream(path: wt.path, ref: pr.headRef)
        }
        let head = wt.head ?? ""
        if head != pr.headSHA {
            if try await git.isAncestor(path: wt.path, head, pr.headSHA) {
                let merge = try await git.ffMerge(path: wt.path, to: "origin/\(pr.headRef)")
                guard merge.ok else { throw OrcaLauncherError.commandFailed(merge.errorTail) }
            } else if try await !git.isAncestor(path: wt.path, pr.headSHA, head) {
                throw OrcaLauncherError.diverged(pr.headRef)
            }
        }
        return LaunchResult(workspaceRef: wt.id, terminalHandle: try await launchAgent(in: wt.id))
    }

    func reusePrevious() async throws -> LaunchResult {
        if let ref = request.previousWorkspaceRef,
           let wt = try await cli.worktrees().first(where: { $0.repoId == repoId && $0.id == ref }), !wt.isMain {
            try await git.fetch(path: wt.path, ref: pr.headRef)
            if try await git.ffMerge(path: wt.path, to: pr.headSHA).ok { return try await continueIn(wt.id) }
        }
        return try await alwaysNew()
    }

    private func continueIn(_ worktreeId: String) async throws -> LaunchResult {
        // A replayed --retry-launch must not be turned into a send: the lost launch may have started the agent.
        let replayingLaunch = if case .launch = retry { true } else { false }
        if !replayingLaunch, let handle = try await runningAgent(worktreeId) {
            let send = try await cli.send(OrcaCLI.send(terminal: handle, prompt: request.prompt, retry: retry))
            guard send.accepted == true, send.prompt?.stages?.contains("input_accepted") == true else { throw OrcaLauncherError.sendNotAccepted }
            return LaunchResult(workspaceRef: worktreeId, terminalHandle: handle, reusedWorkspace: true, sentToExistingSession: true,
                                retryToken: send.prompt?.requestId.map { RetryToken.request($0).stored })
        }
        return LaunchResult(workspaceRef: worktreeId, terminalHandle: try await launchAgent(in: worktreeId), reusedWorkspace: true)
    }

    private func launchAgent(in worktreeId: String) async throws -> String {
        try Self.handle(try await cli.launchAgent(OrcaCLI.launchAgent(worktree: worktreeId, prompt: request.prompt, settings: s, retry: retry)))
    }

    private static func handle(_ launch: OrcaCLI.AgentLaunch?) throws -> String {
        guard launch?.outcome?.kind == "terminal", let handle = launch?.outcome?.handle else { throw OrcaLauncherError.chatSurface }
        let outcome = launch?.prompt?.outcome ?? "none"
        guard outcome == "handed-to-terminal" else { throw OrcaLauncherError.promptNotHanded(outcome) }
        return handle
    }

    /// Agent identity lingers for a few seconds after the agent exits, so require two matches 3 s apart
    /// before typing into the terminal; otherwise the prompt could run as a shell command.
    private func runningAgent(_ worktreeId: String) async throws -> String? {
        func live() async throws -> [String] {
            try await cli.terminals(worktree: worktreeId).filter {
                $0.agentIdentity == s.agent && $0.connected == true && $0.writable == true && $0.orphaned != true
            }.map(\.handle)
        }
        let first = try await live()
        guard let handle = first.first(where: { $0 == request.previousTerminalHandle }) ?? first.first else { return nil }
        await sleep(.seconds(3))
        return try await live().contains(handle) ? handle : nil
    }
}
