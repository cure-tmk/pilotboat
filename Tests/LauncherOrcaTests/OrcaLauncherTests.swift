import Core
import Foundation
import ProcessKit
import Testing
@testable import LauncherOrca

final class ScriptedRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [(prefix: [String], result: CommandResult)]
    private(set) var calls: [[String]] = []

    init(_ rules: [([String], CommandResult)]) { self.rules = rules.map { (prefix: $0.0, result: $0.1) } }

    func run(_ command: Command) async throws -> CommandResult {
        lock.withLock {
            let argv = [command.executable] + command.arguments
            calls.append(argv)
            guard let i = rules.firstIndex(where: { argv.starts(with: $0.prefix) }) else {
                return CommandResult(exitCode: 99, stdout: Data(), stderr: Data("unscripted: \(argv)".utf8))
            }
            return rules.remove(at: i).result
        }
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []
    var durations: [Duration] { lock.withLock { _durations } }
    var sleep: @Sendable (Duration) async -> Void { { d in self.lock.withLock { self._durations.append(d) } } }
}

func ok(_ result: String) -> CommandResult { CommandResult(exitCode: 0, stdout: Data(#"{"ok":true,"result":\#(result)}"#.utf8), stderr: Data()) }
func fail(_ code: String, _ extra: String = "") -> CommandResult {
    CommandResult(exitCode: 1, stdout: Data(#"{"ok":false,"error":{"code":"\#(code)","message":"\#(code)"\#(extra)}}"#.utf8), stderr: Data())
}
func gitStatus(_ code: Int32, _ stderr: String = "") -> CommandResult { CommandResult(exitCode: code, stdout: Data(), stderr: Data(stderr.utf8)) }

let repoId = "repo-1"
let wtId = "repo-1::/wt/pr-7"
let headSHA = "bbbb"
let prompt = "Review https://github.com/o/r/pull/7\nline 2; rm -rf /"

let repoList = ok(#"{"repos":[{"id":"repo-1","path":"/src/r","displayName":"r","gitRemoteIdentity":{"canonicalKey":"github.com/o/r"}}]}"#)
func worktreeList(branch: String = "refs/heads/feature/x", head: String = headSHA, isMain: Bool = false) -> CommandResult {
    ok(#"{"worktrees":[{"id":"other::/x","repoId":"other","path":"/x","branch":"refs/heads/feature/x","head":"0","isMainWorktree":false},{"id":"\#(wtId)","repoId":"repo-1","path":"/wt/pr-7","branch":"\#(branch)","head":"\#(head)","isMainWorktree":\#(isMain)}]}"#)
}
func launchJSON(kind: String = "terminal", promptOutcome: String = "handed-to-terminal") -> String {
    #"{"worktreeId":"\#(wtId)","outcome":{"kind":"\#(kind)","handle":"term_new"},"prompt":{"outcome":"\#(promptOutcome)"}}"#
}
func terminals(agent: String? = "claude", handle: String = "term_live") -> CommandResult {
    let identity = agent.map { #","agentIdentity":"\#($0)""# } ?? ""
    return ok(#"{"terminals":[{"handle":"\#(handle)","connected":true,"writable":true,"orphaned":false\#(identity)}]}"#)
}

func request(_ policy: WorkspacePolicy, binding: String? = repoId, settings: [String: JSONValue] = [:], previousHandle: String? = nil, retryToken: String? = nil) -> LaunchRequest {
    let pr = PullRequestRef(host: "github.com", repo: "o/r", number: 7, url: URL(string: "https://github.com/o/r/pull/7")!, title: "t", headRef: "feature/x", headSHA: headSHA, baseRef: "main", isDraft: false, isCrossRepository: false, labels: [], author: "a")
    return LaunchRequest(runId: UUID(), subject: .pullRequest(pr), repository: RepositoryInfo(host: "github.com", fullName: "o/r", launcherBinding: binding), workspacePolicy: policy, prompt: prompt, previousTerminalHandle: previousHandle, launcherSettings: .object(["agent": .string("claude")].merging(settings) { $1 }), retryToken: retryToken)
}

let createReview = ["orca", "worktree", "create", "--repo", "id:repo-1", "--name", "pr-7-review", "--base-branch", headSHA, "--pr", "7", "--no-parent", "--agent", "claude", "--surface", "terminal", "--prompt", prompt, "--setup", "skip"]
let agentLaunch = ["orca", "agent", "launch", "--worktree", "id:\(wtId)", "--agent", "claude", "--surface", "terminal", "--prompt", prompt, "--json"]
let termList = ["orca", "terminal", "list", "--worktree", "id:\(wtId)", "--json"]

@Test func alwaysNewHappyPath() async throws {
    let runner = ScriptedRunner([(["orca", "repo"], repoList), (["git"], gitStatus(0)), (["orca", "worktree", "create"], ok(#"{"launch":\#(launchJSON())}"#))])
    let result = try await OrcaLauncher(runner: runner).launch(request(.alwaysNew, settings: ["model": .string("opus"), "effort": .string("high")]))
    #expect(runner.calls == [
        ["orca", "repo", "list", "--json"],
        ["git", "-C", "/src/r", "fetch", "origin", "feature/x"],
        createReview + ["--model", "opus", "--effort", "high", "--json"],
    ])
    #expect(result.workspaceRef == wtId && result.terminalHandle == "term_new" && !result.reusedWorkspace)
}

@Test func alwaysNewPromptNotHandedAndChatSurface() async throws {
    let notHanded = ScriptedRunner([(["orca", "repo"], repoList), (["git"], gitStatus(0)), (["orca", "worktree", "create"], ok(#"{"launch":\#(launchJSON(promptOutcome: "journaled"))}"#))])
    await #expect(throws: OrcaLauncherError.promptNotHanded("journaled")) { try await OrcaLauncher(runner: notHanded).launch(request(.alwaysNew)) }
    let chat = ScriptedRunner([(["orca", "repo"], repoList), (["git"], gitStatus(0)), (["orca", "worktree", "create"], ok(#"{"launch":\#(launchJSON(kind: "structured"))}"#))])
    await #expect(throws: OrcaLauncherError.chatSurface) { try await OrcaLauncher(runner: chat).launch(request(.alwaysNew)) }
}

@Test func reuseSendsToRunningAgent() async throws {
    let sleeper = SleepRecorder()
    let runner = ScriptedRunner([
        (["orca", "worktree", "list"], worktreeList()),
        (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "send"], ok(#"{"send":{"accepted":true,"prompt":{"requestId":"req_1","stages":["input_accepted","turn_started"]}}}"#)),
    ])
    let result = try await OrcaLauncher(runner: runner, sleep: sleeper.sleep).launch(request(.reuseOrCreate, previousHandle: "term_gone"))
    #expect(runner.calls == [
        ["orca", "worktree", "list", "--json"], termList, termList,
        ["orca", "terminal", "send", "--terminal", "term_live", "--text", prompt, "--enter", "--wait-submit", "10", "--json"],
    ])
    #expect(sleeper.durations == [.seconds(3)])
    #expect(result.reusedWorkspace && result.sentToExistingSession && result.terminalHandle == "term_live" && result.retryToken == "request:req_1")
}

@Test func reuseSendWithoutInputAcceptedFails() async throws {
    let runner = ScriptedRunner([
        (["orca", "worktree", "list"], worktreeList()), (["orca", "terminal", "list"], terminals()), (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "send"], ok(#"{"send":{"accepted":true,"prompt":{"stages":[]}}}"#)),
    ])
    await #expect(throws: OrcaLauncherError.sendNotAccepted) { try await OrcaLauncher(runner: runner, sleep: { _ in }).launch(request(.reuseOrCreate)) }
}

@Test func agentGoneBetweenChecksLaunchesInstead() async throws {
    let runner = ScriptedRunner([
        (["orca", "worktree", "list"], worktreeList()),
        (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "list"], terminals(agent: nil)),
        (["orca", "agent", "launch"], ok(launchJSON())),
    ])
    let result = try await OrcaLauncher(runner: runner, sleep: { _ in }).launch(request(.reuseOrCreate))
    #expect(runner.calls == [["orca", "worktree", "list", "--json"], termList, termList, agentLaunch])
    #expect(result.reusedWorkspace && !result.sentToExistingSession && result.terminalHandle == "term_new")
}

@Test func reuseWithoutAgentLaunches() async throws {
    let sleeper = SleepRecorder()
    let runner = ScriptedRunner([
        (["orca", "worktree", "list"], worktreeList()),
        (["orca", "terminal", "list"], terminals(agent: "codex")),
        (["orca", "agent", "launch"], ok(launchJSON())),
    ])
    _ = try await OrcaLauncher(runner: runner, sleep: sleeper.sleep).launch(request(.reuseOrCreate))
    #expect(runner.calls == [["orca", "worktree", "list", "--json"], termList, agentLaunch])
    #expect(sleeper.durations.isEmpty)
}

@Test func mainWorktreeIsRefused() async throws {
    let runner = ScriptedRunner([(["orca", "worktree", "list"], worktreeList(isMain: true))])
    await #expect(throws: OrcaLauncherError.headCheckedOutInMainWorktree("feature/x")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
    #expect(runner.calls.count == 1)
}

func createPathRules(created: CommandResult, tail: [([String], CommandResult)]) -> [([String], CommandResult)] {
    [(["orca", "worktree", "list"], ok(#"{"worktrees":[]}"#)), (["orca", "repo"], repoList), (["git", "-C", "/src/r", "fetch"], gitStatus(0)),
     (["orca", "worktree", "create"], ok(#"{"worktree":{"id":"\#(wtId)"}}"#)), (["orca", "worktree", "list"], created)] + tail
}

@Test func createPathSetsUpstreamAndFastForwards() async throws {
    let runner = ScriptedRunner(createPathRules(created: worktreeList(head: "aaaa"), tail: [
        (["git", "-C", "/wt/pr-7", "rev-parse"], gitStatus(128, "no upstream")),
        (["git", "-C", "/wt/pr-7", "branch"], gitStatus(0)),
        (["git", "-C", "/wt/pr-7", "merge-base"], gitStatus(0)),
        (["git", "-C", "/wt/pr-7", "merge"], gitStatus(0)),
        (["orca", "agent", "launch"], ok(launchJSON())),
    ]))
    let result = try await OrcaLauncher(runner: runner, settingsOverride: OrcaSettings(agent: "claude", activate: true)).launch(request(.reuseOrCreate))
    #expect(runner.calls == [
        ["orca", "worktree", "list", "--json"],
        ["orca", "repo", "list", "--json"],
        ["git", "-C", "/src/r", "fetch", "origin", "feature/x"],
        ["orca", "worktree", "create", "--repo", "id:repo-1", "--name", "pr-7", "--branch", "feature/x", "--base-branch", "origin/feature/x", "--pr", "7", "--no-parent", "--setup", "inherit", "--activate", "--json"],
        ["orca", "worktree", "list", "--json"],
        ["git", "-C", "/wt/pr-7", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        ["git", "-C", "/wt/pr-7", "branch", "--set-upstream-to=origin/feature/x"],
        ["git", "-C", "/wt/pr-7", "merge-base", "--is-ancestor", "aaaa", headSHA],
        ["git", "-C", "/wt/pr-7", "merge", "--ff-only", "origin/feature/x"],
        Array(agentLaunch.dropLast()) + ["--focus", "--json"],
    ])
    #expect(result.workspaceRef == wtId && !result.reusedWorkspace)
}

@Test func createPathDivergedFails() async throws {
    let runner = ScriptedRunner(createPathRules(created: worktreeList(head: "cccc"), tail: [
        (["git", "-C", "/wt/pr-7", "rev-parse"], gitStatus(0)),
        (["git", "-C", "/wt/pr-7", "merge-base"], gitStatus(1)),
        (["git", "-C", "/wt/pr-7", "merge-base"], gitStatus(1)),
    ]))
    await #expect(throws: OrcaLauncherError.diverged("feature/x")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
    #expect(!runner.calls.contains { $0.starts(with: ["orca", "agent"]) })
}

@Test func createPathBranchMismatchFails() async throws {
    let runner = ScriptedRunner(createPathRules(created: worktreeList(branch: "refs/heads/me/pr-7"), tail: []))
    await #expect(throws: OrcaLauncherError.branchMismatch(expected: "refs/heads/feature/x", actual: "refs/heads/me/pr-7")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
}

@Test func retryTokenIsSurfacedAndReplayed() async throws {
    let lost = ScriptedRunner([(["orca", "repo"], repoList), (["git"], gitStatus(0)),
        (["orca", "worktree", "create"], fail("transport_lost", #","data":{"nextSteps":["Re-issue the exact same command with --retry-launch op_9. Keep that ID."]}"#))])
    await #expect(throws: OrcaRetryableError(retryToken: "launch:op_9", message: "transport_lost\nRe-issue the exact same command with --retry-launch op_9. Keep that ID.")) {
        try await OrcaLauncher(runner: lost).launch(request(.alwaysNew))
    }

    let replay = ScriptedRunner([(["orca", "repo"], repoList), (["git"], gitStatus(0)), (["orca", "worktree", "create"], ok(#"{"launch":\#(launchJSON())}"#))])
    _ = try await OrcaLauncher(runner: replay).launch(request(.alwaysNew, retryToken: "launch:op_9"))
    #expect(replay.calls.last == createReview + ["--retry-launch", "op_9", "--json"])

    let resend = ScriptedRunner([
        (["orca", "worktree", "list"], worktreeList()), (["orca", "terminal", "list"], terminals()), (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "send"], ok(#"{"send":{"accepted":true,"prompt":{"stages":["input_accepted"]}}}"#)),
    ])
    _ = try await OrcaLauncher(runner: resend, sleep: { _ in }).launch(request(.reuseOrCreate, retryToken: "request:req_1"))
    #expect(resend.calls.last == ["orca", "terminal", "send", "--terminal", "term_live", "--text", prompt, "--enter", "--wait-submit", "10", "--retry-request", "req_1", "--json"])
}

@Test func notRunningOpensOrcaAndRetriesOnce() async throws {
    let runner = ScriptedRunner([
        (["orca", "worktree", "list"], fail("runtime_unavailable")),
        (["orca", "open"], ok("{}")),
        (["orca", "worktree", "list"], worktreeList(isMain: true)),
    ])
    await #expect(throws: OrcaLauncherError.headCheckedOutInMainWorktree("feature/x")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
    #expect(runner.calls == [["orca", "worktree", "list", "--json"], ["orca", "open", "--json"], ["orca", "worktree", "list", "--json"]])

    let stillDown = ScriptedRunner([(["orca", "worktree", "list"], fail("runtime_unavailable")), (["orca", "open"], ok("{}")), (["orca", "worktree", "list"], fail("runtime_unavailable"))])
    await #expect(throws: OrcaLauncherError.notRunning) { try await OrcaLauncher(runner: stillDown).launch(request(.reuseOrCreate)) }
}

@Test func missingBindingFails() async throws {
    let runner = ScriptedRunner([])
    await #expect(throws: OrcaLauncherError.notBound("o/r")) { try await OrcaLauncher(runner: runner).launch(request(.alwaysNew, binding: nil)) }
    #expect(runner.calls.isEmpty)
}

@Test func listReposReadsCanonicalKey() async throws {
    let repos = try await OrcaLauncher(runner: ScriptedRunner([(["orca", "repo"], repoList)])).listRepos()
    #expect(repos == [OrcaRepo(id: "repo-1", path: "/src/r", displayName: "r", canonicalKey: "github.com/o/r")])
}

@Test func diagnoseAndOpenUseOrcaPathFromSettings() async throws {
    let settings = JSONValue.object(["orcaPath": .string("/opt/orca"), "agent": .string("claude")])
    let runner = ScriptedRunner([(["/opt/orca", "terminal", "list"], ok(#"{"terminals":[{"handle":"t1"}]}"#)), (["/opt/orca", "terminal", "switch"], ok("{}"))])
    let launcher = OrcaLauncher(runner: runner)
    _ = await launcher.diagnose(settings: settings)
    try await launcher.open(wtId, settings: settings)
    #expect(runner.calls.allSatisfy { $0[0] == "/opt/orca" })
    #expect(runner.calls.suffix(2) == [["/opt/orca", "terminal", "list", "--worktree", "id:\(wtId)", "--json"], ["/opt/orca", "terminal", "switch", "--terminal", "t1", "--json"]])
}
