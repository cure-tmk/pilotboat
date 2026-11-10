import Core
import Foundation
import ProcessKit
import Testing
@testable import LauncherOrca

typealias Rule = (prefix: [String], result: CommandResult)

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []
    var durations: [Duration] { lock.withLock { _durations } }
    var sleep: @Sendable (Duration) async -> Void { { d in self.lock.withLock { self._durations.append(d) } } }
}

extension FakeCommandRunner {
    var argv: [[String]] { calls.map { [$0.executable] + $0.arguments } }
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
let mainRow = #"{"id":"repo-1::/src/r","repoId":"repo-1","path":"/src/r","branch":"refs/heads/main","head":"0","isMainWorktree":true}"#
func worktreeList(branch: String = "refs/heads/feature/x", head: String = headSHA, isMain: Bool = false) -> CommandResult {
    ok(#"{"worktrees":[{"id":"other::/x","repoId":"other","path":"/x","branch":"refs/heads/feature/x","head":"0","isMainWorktree":false},{"id":"\#(wtId)","repoId":"repo-1","path":"/wt/pr-7","branch":"\#(branch)","head":"\#(head)","isMainWorktree":\#(isMain)}]}"#)
}
func launchJSON(kind: String = "terminal", promptOutcome: String = "handed-to-terminal", worktreeId: String? = wtId) -> String {
    let id = worktreeId.map { #""worktreeId":"\#($0)","# } ?? ""
    return #"{\#(id)"outcome":{"kind":"\#(kind)","handle":"term_new"},"prompt":{"outcome":"\#(promptOutcome)"}}"#
}
func terminals(agent: String? = "claude", handle: String = "term_live") -> CommandResult {
    let identity = agent.map { #","agentIdentity":"\#($0)""# } ?? ""
    return ok(#"{"terminals":[{"handle":"\#(handle)","connected":true,"writable":true,"orphaned":false\#(identity)}]}"#)
}
let sendAccepted = ok(#"{"send":{"accepted":true,"prompt":{"requestId":"req_1","stages":["input_accepted","turn_started"]}}}"#)

func request(_ policy: WorkspacePolicy, binding: String? = repoId, settings: [String: JSONValue] = [:], previousRef: String? = nil, previousHandle: String? = nil, retryToken: String? = nil) -> LaunchRequest {
    let pr = PullRequestRef(host: "github.com", repo: "o/r", number: 7, url: URL(string: "https://github.com/o/r/pull/7")!, title: "t", headRef: "feature/x", headSHA: headSHA, baseRef: "main", isDraft: false, isCrossRepository: false, labels: [], author: "a")
    return LaunchRequest(runId: UUID(), subject: .pullRequest(pr), repository: RepositoryInfo(host: "github.com", fullName: "o/r", launcherBinding: binding), workspacePolicy: policy, prompt: prompt, previousWorkspaceRef: previousRef, previousTerminalHandle: previousHandle, launcherSettings: .object(["agent": .string("claude")].merging(settings) { $1 }), retryToken: retryToken)
}

let createReview = ["orca", "worktree", "create", "--repo", "id:repo-1", "--name", "pr-7-review", "--base-branch", headSHA, "--pr", "7", "--no-parent", "--agent", "claude", "--surface", "terminal", "--prompt", prompt, "--setup", "skip"]
let agentLaunch = ["orca", "agent", "launch", "--worktree", "id:\(wtId)", "--agent", "claude", "--surface", "terminal", "--prompt", prompt, "--json"]
let termList = ["orca", "terminal", "list", "--worktree", "id:\(wtId)", "--json"]
let sendCall = ["orca", "terminal", "send", "--terminal", "term_live", "--text", prompt, "--enter", "--wait-submit", "10", "--json"]

@Test func alwaysNewHappyPath() async throws {
    let runner = FakeCommandRunner(rules: [(["orca", "repo"], repoList), (["git"], gitStatus(0)), (["orca", "worktree", "create"], ok(#"{"launch":\#(launchJSON())}"#))])
    let result = try await OrcaLauncher(runner: runner).launch(request(.alwaysNew, settings: ["model": .string("opus"), "effort": .string("high")]))
    #expect(runner.argv == [
        ["orca", "repo", "list", "--json"],
        ["git", "-C", "/src/r", "fetch", "origin", "feature/x"],
        createReview + ["--model", "opus", "--effort", "high", "--json"],
    ])
    #expect(result.workspaceRef == wtId && result.terminalHandle == "term_new" && !result.reusedWorkspace)
}

@Test func alwaysNewFallsBackToWorktreeIdAndRequiresOne() async throws {
    let fallback = FakeCommandRunner(rules: [(["orca", "repo"], repoList), (["git"], gitStatus(0)),
        (["orca", "worktree", "create"], ok(#"{"worktree":{"id":"wt-from-create"},"launch":\#(launchJSON(worktreeId: nil))}"#))])
    #expect(try await OrcaLauncher(runner: fallback).launch(request(.alwaysNew)).workspaceRef == "wt-from-create")

    let none = FakeCommandRunner(rules: [(["orca", "repo"], repoList), (["git"], gitStatus(0)), (["orca", "worktree", "create"], ok(#"{"launch":\#(launchJSON(worktreeId: nil))}"#))])
    await #expect(throws: OrcaLauncherError.commandFailed("orca worktree create returned no worktree id")) { try await OrcaLauncher(runner: none).launch(request(.alwaysNew)) }
}

@Test func alwaysNewPromptNotHandedAndChatSurface() async throws {
    let notHanded = FakeCommandRunner(rules: [(["orca", "repo"], repoList), (["git"], gitStatus(0)), (["orca", "worktree", "create"], ok(#"{"launch":\#(launchJSON(promptOutcome: "journaled"))}"#))])
    await #expect(throws: OrcaLauncherError.promptNotHanded("journaled")) { try await OrcaLauncher(runner: notHanded).launch(request(.alwaysNew)) }
    let chat = FakeCommandRunner(rules: [(["orca", "repo"], repoList), (["git"], gitStatus(0)), (["orca", "worktree", "create"], ok(#"{"launch":\#(launchJSON(kind: "structured"))}"#))])
    await #expect(throws: OrcaLauncherError.chatSurface) { try await OrcaLauncher(runner: chat).launch(request(.alwaysNew)) }
}

@Test func reuseSendsToRunningAgent() async throws {
    let sleeper = SleepRecorder()
    let runner = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], worktreeList()),
        (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "send"], sendAccepted),
    ])
    let result = try await OrcaLauncher(runner: runner, sleep: sleeper.sleep).launch(request(.reuseOrCreate, previousHandle: "term_gone"))
    #expect(runner.argv == [["orca", "worktree", "list", "--json"], termList, termList, sendCall])
    #expect(sleeper.durations == [.seconds(3)])
    #expect(result.reusedWorkspace && result.sentToExistingSession && result.terminalHandle == "term_live" && result.retryToken == "request:req_1")
}

@Test func reuseSendWithoutInputAcceptedFails() async throws {
    let runner = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], worktreeList()), (["orca", "terminal", "list"], terminals()), (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "send"], ok(#"{"send":{"accepted":true,"prompt":{"stages":[]}}}"#)),
    ])
    await #expect(throws: OrcaLauncherError.sendNotAccepted) { try await OrcaLauncher(runner: runner, sleep: { _ in }).launch(request(.reuseOrCreate)) }
}

@Test func reuseSendWithoutSendKeyIsNotAccepted() async throws {
    for body in [#"{}"#, #"{"send":null}"#] {
        let runner = FakeCommandRunner(rules: [
            (["orca", "worktree", "list"], worktreeList()), (["orca", "terminal", "list"], terminals()), (["orca", "terminal", "list"], terminals()),
            (["orca", "terminal", "send"], ok(body)),
        ])
        await #expect(throws: OrcaLauncherError.sendNotAccepted) { try await OrcaLauncher(runner: runner, sleep: { _ in }).launch(request(.reuseOrCreate)) }
    }
}

@Test func agentGoneBetweenChecksLaunchesInstead() async throws {
    let runner = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], worktreeList()),
        (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "list"], terminals(agent: nil)),
        (["orca", "agent", "launch"], ok(launchJSON())),
    ])
    let result = try await OrcaLauncher(runner: runner, sleep: { _ in }).launch(request(.reuseOrCreate))
    #expect(runner.argv == [["orca", "worktree", "list", "--json"], termList, termList, agentLaunch])
    #expect(result.reusedWorkspace && !result.sentToExistingSession && result.terminalHandle == "term_new")
}

@Test func reuseWithoutAgentLaunches() async throws {
    let sleeper = SleepRecorder()
    let runner = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], worktreeList()),
        (["orca", "terminal", "list"], terminals(agent: "codex")),
        (["orca", "agent", "launch"], ok(launchJSON())),
    ])
    _ = try await OrcaLauncher(runner: runner, sleep: sleeper.sleep).launch(request(.reuseOrCreate))
    #expect(runner.argv == [["orca", "worktree", "list", "--json"], termList, agentLaunch])
    #expect(sleeper.durations.isEmpty)
}

@Test func retryLaunchOnReuseNeverSends() async throws {
    let runner = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], worktreeList()),
        (["orca", "agent", "launch"], ok(launchJSON())),
    ])
    let result = try await OrcaLauncher(runner: runner, sleep: { _ in }).launch(request(.reuseOrCreate, retryToken: "launch:op_9"))
    #expect(runner.argv == [["orca", "worktree", "list", "--json"], Array(agentLaunch.dropLast()) + ["--retry-launch", "op_9", "--json"]])
    #expect(!result.sentToExistingSession)
}

@Test func mainWorktreeIsRefused() async throws {
    let runner = FakeCommandRunner(rules: [(["orca", "worktree", "list"], worktreeList(isMain: true))])
    await #expect(throws: OrcaLauncherError.headCheckedOutInMainWorktree("feature/x")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
    #expect(runner.calls.count == 1)
}

func createPathRules(created: CommandResult, createResponse: CommandResult = ok(#"{"worktree":{"id":"\#(wtId)"}}"#), tail: [Rule]) -> [Rule] {
    [(["orca", "worktree", "list"], ok(#"{"worktrees":[\#(mainRow)]}"#)), (["git", "-C", "/src/r", "fetch"], gitStatus(0)),
     (["orca", "worktree", "create"], createResponse), (["orca", "worktree", "list"], created)] + tail
}

@Test func createPathSetsUpstreamAndFastForwards() async throws {
    let runner = FakeCommandRunner(rules: createPathRules(created: worktreeList(head: "aaaa"), tail: [
        (["git", "-C", "/wt/pr-7", "rev-parse"], gitStatus(128, "no upstream")),
        (["git", "-C", "/wt/pr-7", "branch"], gitStatus(0)),
        (["git", "-C", "/wt/pr-7", "merge-base"], gitStatus(0)),
        (["git", "-C", "/wt/pr-7", "merge"], gitStatus(0)),
        (["orca", "agent", "launch"], ok(launchJSON())),
    ]))
    let result = try await OrcaLauncher(runner: runner, settingsOverride: OrcaSettings(agent: "claude", activate: true)).launch(request(.reuseOrCreate))
    #expect(runner.argv == [
        ["orca", "worktree", "list", "--json"],
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

@Test func createPathWithUpstreamAtHeadSkipsGitMerge() async throws {
    let runner = FakeCommandRunner(rules: createPathRules(created: worktreeList(), tail: [
        (["git", "-C", "/wt/pr-7", "rev-parse"], gitStatus(0)),
        (["orca", "agent", "launch"], ok(launchJSON())),
    ]))
    _ = try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate))
    #expect(runner.argv.suffix(2) == [["git", "-C", "/wt/pr-7", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], agentLaunch])
}

@Test func createPathWithoutMainWorktreeFallsBackToRepoList() async throws {
    let runner = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], ok(#"{"worktrees":[]}"#)), (["orca", "repo"], repoList), (["git", "-C", "/src/r", "fetch"], gitStatus(0)),
        (["orca", "worktree", "create"], ok(#"{"worktree":{"id":"\#(wtId)"}}"#)), (["orca", "worktree", "list"], worktreeList()),
        (["git", "-C", "/wt/pr-7", "rev-parse"], gitStatus(0)), (["orca", "agent", "launch"], ok(launchJSON())),
    ])
    let result = try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate))
    #expect(runner.argv.prefix(3) == [["orca", "worktree", "list", "--json"], ["orca", "repo", "list", "--json"], ["git", "-C", "/src/r", "fetch", "origin", "feature/x"]])
    #expect(result.workspaceRef == wtId && result.terminalHandle == "term_new")

    let missing = FakeCommandRunner(rules: [(["orca", "worktree", "list"], ok(#"{"worktrees":[]}"#)), (["orca", "repo"], ok(#"{"repos":[]}"#))])
    await #expect(throws: OrcaLauncherError.repoNotFound(repoId)) { try await OrcaLauncher(runner: missing).launch(request(.reuseOrCreate)) }
    #expect(missing.calls.count == 2)
}

@Test func createPathFastForwardFailureSurfacesGitError() async throws {
    let runner = FakeCommandRunner(rules: createPathRules(created: worktreeList(head: "aaaa"), tail: [
        (["git", "-C", "/wt/pr-7", "rev-parse"], gitStatus(0)),
        (["git", "-C", "/wt/pr-7", "merge-base"], gitStatus(0)),
        (["git", "-C", "/wt/pr-7", "merge"], gitStatus(128, "fatal: Not possible to fast-forward, aborting.")),
    ]))
    await #expect(throws: OrcaLauncherError.commandFailed("fatal: Not possible to fast-forward, aborting.")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
    #expect(!runner.argv.contains { $0.starts(with: ["orca", "agent"]) })
}

@Test func createPathResponseMissingIdFails() async throws {
    let runner = FakeCommandRunner(rules: createPathRules(created: worktreeList(), createResponse: ok(#"{"worktree":{}}"#), tail: []))
    await #expect(throws: OrcaLauncherError.commandFailed("orca worktree create returned no worktree id")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
    #expect(runner.calls.count == 3)
}

@Test func createPathDivergedFails() async throws {
    let runner = FakeCommandRunner(rules: createPathRules(created: worktreeList(head: "cccc"), tail: [
        (["git", "-C", "/wt/pr-7", "rev-parse"], gitStatus(0)),
        (["git", "-C", "/wt/pr-7", "merge-base"], gitStatus(1)),
        (["git", "-C", "/wt/pr-7", "merge-base"], gitStatus(1)),
    ]))
    await #expect(throws: OrcaLauncherError.diverged("feature/x")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
    #expect(!runner.argv.contains { $0.starts(with: ["orca", "agent"]) })
}

@Test func createPathIsAncestorErrorFails() async throws {
    let runner = FakeCommandRunner(rules: createPathRules(created: worktreeList(head: "cccc"), tail: [
        (["git", "-C", "/wt/pr-7", "rev-parse"], gitStatus(0)),
        (["git", "-C", "/wt/pr-7", "merge-base"], gitStatus(128, "fatal: Not a valid commit name cccc")),
    ]))
    await #expect(throws: OrcaLauncherError.commandFailed("fatal: Not a valid commit name cccc")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
}

@Test func createPathBranchMismatchFails() async throws {
    let runner = FakeCommandRunner(rules: createPathRules(created: worktreeList(branch: "refs/heads/me/pr-7"), tail: []))
    await #expect(throws: OrcaLauncherError.branchMismatch(expected: "refs/heads/feature/x", actual: "refs/heads/me/pr-7")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
}

let fetchPrevious = ["git", "-C", "/wt/pr-7", "fetch", "origin", "feature/x"]
let mergePrevious = ["git", "-C", "/wt/pr-7", "merge", "--ff-only", headSHA]
let alwaysNewRules: [Rule] = [(["orca", "repo"], repoList), (["git", "-C", "/src/r"], gitStatus(0)), (["orca", "worktree", "create"], ok(#"{"launch":\#(launchJSON())}"#))]
let alwaysNewCalls = [["orca", "repo", "list", "--json"], ["git", "-C", "/src/r", "fetch", "origin", "feature/x"], createReview + ["--json"]]

@Test func reusePreviousUpdatesAndSendsToRunningAgent() async throws {
    let sleeper = SleepRecorder()
    let runner = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], worktreeList(head: "aaaa")),
        (fetchPrevious, gitStatus(0)), (mergePrevious, gitStatus(0)),
        (["orca", "terminal", "list"], terminals()), (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "send"], sendAccepted),
    ])
    let result = try await OrcaLauncher(runner: runner, sleep: sleeper.sleep).launch(request(.reusePrevious, previousRef: wtId, previousHandle: "term_live"))
    #expect(runner.argv == [["orca", "worktree", "list", "--json"], fetchPrevious, mergePrevious, termList, termList, sendCall])
    #expect(sleeper.durations == [.seconds(3)])
    #expect(result.workspaceRef == wtId && result.reusedWorkspace && result.sentToExistingSession && result.terminalHandle == "term_live")
}

@Test func reusePreviousWithoutAgentLaunches() async throws {
    let runner = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], worktreeList()), (fetchPrevious, gitStatus(0)), (mergePrevious, gitStatus(0)),
        (["orca", "terminal", "list"], ok(#"{"terminals":[]}"#)), (["orca", "agent", "launch"], ok(launchJSON())),
    ])
    let result = try await OrcaLauncher(runner: runner, sleep: { _ in }).launch(request(.reusePrevious, previousRef: wtId))
    #expect(runner.argv == [["orca", "worktree", "list", "--json"], fetchPrevious, mergePrevious, termList, agentLaunch])
    #expect(result.workspaceRef == wtId && result.reusedWorkspace && !result.sentToExistingSession && result.terminalHandle == "term_new")
}

@Test func reusePreviousFallsBackToNewWorktree() async throws {
    let missing = FakeCommandRunner(rules: [(["orca", "worktree", "list"], worktreeList())] + alwaysNewRules)
    let fresh = try await OrcaLauncher(runner: missing).launch(request(.reusePrevious, previousRef: "repo-1::/wt/gone"))
    #expect(missing.argv == [["orca", "worktree", "list", "--json"]] + alwaysNewCalls)
    #expect(!fresh.reusedWorkspace)

    let main = FakeCommandRunner(rules: [(["orca", "worktree", "list"], worktreeList(isMain: true))] + alwaysNewRules)
    _ = try await OrcaLauncher(runner: main).launch(request(.reusePrevious, previousRef: wtId))
    #expect(main.argv == [["orca", "worktree", "list", "--json"]] + alwaysNewCalls)

    let noPrevious = FakeCommandRunner(rules: alwaysNewRules)
    _ = try await OrcaLauncher(runner: noPrevious).launch(request(.reusePrevious))
    #expect(noPrevious.argv == alwaysNewCalls)
}

@Test func reusePreviousMergeFailureFallsBackToNewWorktree() async throws {
    let runner = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], worktreeList()), (fetchPrevious, gitStatus(0)), (mergePrevious, gitStatus(128, "Not possible to fast-forward")),
    ] + alwaysNewRules)
    let result = try await OrcaLauncher(runner: runner).launch(request(.reusePrevious, previousRef: wtId))
    #expect(runner.argv == [["orca", "worktree", "list", "--json"], fetchPrevious, mergePrevious] + alwaysNewCalls)
    #expect(!result.reusedWorkspace && result.terminalHandle == "term_new")
}

@Test func retryTokenIsSurfacedAndReplayed() async throws {
    let lost = FakeCommandRunner(rules: [(["orca", "repo"], repoList), (["git"], gitStatus(0)),
        (["orca", "worktree", "create"], fail("transport_lost", #","data":{"nextSteps":["Re-issue the exact same command with --retry-launch op_9. Keep that ID."]}"#))])
    await #expect(throws: OrcaRetryableError(retryToken: "launch:op_9", message: "transport_lost\nRe-issue the exact same command with --retry-launch op_9. Keep that ID.")) {
        try await OrcaLauncher(runner: lost).launch(request(.alwaysNew))
    }

    let replay = FakeCommandRunner(rules: [(["orca", "repo"], repoList), (["git"], gitStatus(0)), (["orca", "worktree", "create"], ok(#"{"launch":\#(launchJSON())}"#))])
    _ = try await OrcaLauncher(runner: replay).launch(request(.alwaysNew, retryToken: "launch:op_9"))
    #expect(replay.argv.last == createReview + ["--retry-launch", "op_9", "--json"])

    let resend = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], worktreeList()), (["orca", "terminal", "list"], terminals()), (["orca", "terminal", "list"], terminals()),
        (["orca", "terminal", "send"], ok(#"{"send":{"accepted":true,"prompt":{"stages":["input_accepted"]}}}"#)),
    ])
    _ = try await OrcaLauncher(runner: resend, sleep: { _ in }).launch(request(.reuseOrCreate, retryToken: "request:req_1"))
    #expect(resend.argv.last == Array(sendCall.dropLast()) + ["--retry-request", "req_1", "--json"])
}

@Test func retryTokenStoredForm() {
    #expect(RetryToken(stored: "launch:op:9") == .launch("op:9"))
    #expect(RetryToken(stored: "request:req_1")?.stored == "request:req_1")
    #expect(RetryToken(stored: "other:x") == nil && RetryToken(stored: "nocolon") == nil)
}

@Test func nonJSONFailureSurfacesErrorTail() async throws {
    let runner = FakeCommandRunner(rules: [(["orca", "worktree", "list"], gitStatus(2, "orca: unknown command"))])
    await #expect(throws: OrcaLauncherError.commandFailed("orca: unknown command")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
}

@Test func notRunningOpensOrcaAndRetriesOnce() async throws {
    let runner = FakeCommandRunner(rules: [
        (["orca", "worktree", "list"], fail("runtime_unavailable")),
        (["orca", "open"], ok("{}")),
        (["orca", "worktree", "list"], worktreeList(isMain: true)),
    ])
    await #expect(throws: OrcaLauncherError.headCheckedOutInMainWorktree("feature/x")) { try await OrcaLauncher(runner: runner).launch(request(.reuseOrCreate)) }
    #expect(runner.argv == [["orca", "worktree", "list", "--json"], ["orca", "open", "--json"], ["orca", "worktree", "list", "--json"]])

    let stillDown = FakeCommandRunner(rules: [(["orca", "worktree", "list"], fail("runtime_unavailable")), (["orca", "open"], ok("{}")), (["orca", "worktree", "list"], fail("runtime_unavailable"))])
    await #expect(throws: OrcaLauncherError.notRunning) { try await OrcaLauncher(runner: stillDown).launch(request(.reuseOrCreate)) }

    let openFails = FakeCommandRunner(rules: [(["orca", "worktree", "list"], fail("runtime_unavailable")), (["orca", "open"], gitStatus(1, "cannot launch"))])
    await #expect(throws: OrcaLauncherError.notRunning) { try await OrcaLauncher(runner: openFails).launch(request(.reuseOrCreate)) }
    #expect(openFails.calls.count == 2)
}

@Test func missingBindingFails() async throws {
    let runner = FakeCommandRunner(rules: [])
    await #expect(throws: OrcaLauncherError.notBound("o/r")) { try await OrcaLauncher(runner: runner).launch(request(.alwaysNew, binding: nil)) }
    #expect(runner.calls.isEmpty)
}

@Test func settingsErrors() async throws {
    let runner = FakeCommandRunner(rules: [])
    await #expect(throws: OrcaLauncherError.agentNotConfigured) { try await OrcaLauncher(runner: runner).launch(request(.alwaysNew, settings: ["agent": .string("")])) }
    await #expect(throws: OrcaLauncherError.invalidSettings("agent")) { try await OrcaLauncher(runner: runner).launch(request(.alwaysNew, settings: ["agent": .number(1)])) }
    #expect(throws: OrcaLauncherError.invalidSettings("setupForReview")) { try OrcaSettings(json: .object(["agent": .string("claude"), "setupForReview": .string("always")])) }
    #expect(runner.calls.isEmpty)
}

@Test func settingsRoundTrip() throws {
    #expect(try OrcaSettings(json: .object([:])) == OrcaSettings(agent: ""))
    let settings = OrcaSettings(orcaPath: "/opt/orca", agent: "claude", model: "opus", setupForReview: .run, setupForOwnPR: .skip, activate: true)
    let json = try settings.json()
    #expect(json == .object(["orcaPath": .string("/opt/orca"), "agent": .string("claude"), "model": .string("opus"),
                             "setupForReview": .string("run"), "setupForOwnPR": .string("skip"), "activate": .bool(true)]))
    #expect(try OrcaSettings(json: json) == settings)
}

@Test func repoFullName() {
    let repo = OrcaRepo(id: "1", path: "/p", displayName: "p", canonicalKey: "GitHub.com/Owner/Name")
    #expect(repo.fullName(host: "github.com") == "Owner/Name")
    #expect(repo.fullName(host: "gitlab.com") == nil)
    #expect(OrcaRepo(id: "1", path: "/p", displayName: "p", canonicalKey: nil).fullName(host: "github.com") == nil)
}

@Test func listReposReadsCanonicalKey() async throws {
    let repos = try await OrcaLauncher(runner: FakeCommandRunner(rules: [(["orca", "repo"], repoList)])).listRepos()
    #expect(repos == [OrcaRepo(id: "repo-1", path: "/src/r", displayName: "r", canonicalKey: "github.com/o/r")])
}

@Test func diagnoseAndOpenUseOrcaPathFromSettings() async throws {
    let settings = JSONValue.object(["orcaPath": .string("/opt/orca"), "agent": .string("claude")])
    let runner = FakeCommandRunner(rules: [(["/opt/orca", "terminal", "list"], ok(#"{"terminals":[{"handle":"t1"}]}"#)), (["/opt/orca", "terminal", "switch"], ok("{}"))])
    let launcher = OrcaLauncher(runner: runner)
    _ = await launcher.diagnose(settings: settings)
    try await launcher.open(wtId, settings: settings)
    #expect(runner.argv.allSatisfy { $0[0] == "/opt/orca" })
    #expect(runner.argv.suffix(2) == [["/opt/orca", "terminal", "list", "--worktree", "id:\(wtId)", "--json"], ["/opt/orca", "terminal", "switch", "--terminal", "t1", "--json"]])
}

/// Every command a launch runs must appear verbatim in `describe`, with runtime values replaced by its placeholders.
@Test(arguments: [
    (WorkspacePolicy.alwaysNew, nil as String?, alwaysNewRules),
    (.reusePrevious, nil, [(["orca", "worktree", "list"], worktreeList()), (fetchPrevious, gitStatus(0)), (mergePrevious, gitStatus(0)),
                           (["orca", "terminal", "list"], terminals()), (["orca", "terminal", "list"], terminals()), (["orca", "terminal", "send"], sendAccepted)]),
    (.reusePrevious, "launch:op_9", [(["orca", "worktree", "list"], worktreeList()), (fetchPrevious, gitStatus(0)), (mergePrevious, gitStatus(128))] + alwaysNewRules),
    (.reuseOrCreate, "request:req_1", [(["orca", "worktree", "list"], worktreeList()), (["orca", "terminal", "list"], terminals()),
                                       (["orca", "terminal", "list"], terminals()), (["orca", "terminal", "send"], sendAccepted)]),
    (.reuseOrCreate, "launch:op_9", createPathRules(created: worktreeList(head: "aaaa"), tail: [
        (["git", "-C", "/wt/pr-7", "rev-parse"], gitStatus(128)), (["git", "-C", "/wt/pr-7", "branch"], gitStatus(0)),
        (["git", "-C", "/wt/pr-7", "merge-base"], gitStatus(0)), (["git", "-C", "/wt/pr-7", "merge"], gitStatus(0)), (["orca", "agent", "launch"], ok(launchJSON())),
    ])),
] as [(WorkspacePolicy, String?, [Rule])])
func describeMatchesLaunch(policy: WorkspacePolicy, retry: String?, rules: [Rule]) async throws {
    let settings: [String: JSONValue] = ["model": .string("opus"), "activate": .bool(true)]
    let req = request(policy, settings: settings, previousRef: policy == .reusePrevious ? wtId : nil, retryToken: retry)
    let runner = FakeCommandRunner(rules: rules)
    let launcher = OrcaLauncher(runner: runner, sleep: { _ in })
    _ = try await launcher.launch(req)
    let described = await launcher.describe(req)
    let placeholders = (policy == .reuseOrCreate ? [(wtId, "<worktree-id>"), ("aaaa", "<worktree-head>")] : [])
        + [("-C /wt/pr-7", "-C <worktree-path>"), ("-C /src/r", "-C <repo-path>"), ("term_live", "<handle>")]
    for argv in runner.argv {
        let line = placeholders.reduce(OrcaLauncher.render(argv)) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        #expect(described.contains(line), "missing from describe: \(line)\n\(described)")
    }
    if case .launch = RetryToken(stored: retry ?? "") { #expect(!described.contains("terminal send")) }
}
