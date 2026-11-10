import Core
import Foundation
import ProcessKit
import Testing
@testable import LauncherScript

/// The real runner, with the sample script's Terminal step disabled.
struct DryRunRunner: CommandRunner {
    let base = ProcessRunner(searchPath: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
    func run(_ c: Command) async throws -> CommandResult {
        var c = c
        c.environment = (c.environment ?? [:]).merging(["PILOTBOAT_DRY_RUN": "1"]) { $1 }
        return try await base.run(c)
    }
}

func ok(_ s: String) -> CommandResult { CommandResult(exitCode: 0, stdout: Data(s.utf8), stderr: Data()) }

func makeRequest(exe: String, localPath: String? = nil, policy: WorkspacePolicy = .alwaysNew, prompt: String = "review it", headRef: String = "feature", headSHA: String = "abc", binding: String? = nil) -> LaunchRequest {
    var settings: [String: JSONValue] = ["executable": .string(exe)]
    if let localPath { settings["localPath"] = .string(localPath) }
    let pr = PullRequestRef(host: "github.com", repo: "o/r", number: 7, url: URL(string: "https://github.com/o/r/pull/7")!, title: "t", headRef: headRef, headSHA: headSHA, baseRef: "main", isDraft: false, isCrossRepository: false, labels: [], author: "a")
    return LaunchRequest(runId: UUID(), subject: .pullRequest(pr), repository: RepositoryInfo(host: "github.com", fullName: "o/r", launcherBinding: binding), workspacePolicy: policy, prompt: prompt, launcherSettings: .object(settings))
}

func fake(_ results: [CommandResult]) -> FakeCommandRunner {
    FakeCommandRunner(rules: results.map { (["/bin/x"], $0) })
}

func stdinJSON(_ c: Command) throws -> [String: Any] { try JSONSerialization.jsonObject(with: c.stdin!) as! [String: Any] }

@Suite struct FakeRunnerTests {
    @Test func launchBuildsCommandAndDecodes() async throws {
        let runner = fake([ok(#"{"workspaceRef":"/w","terminalHandle":null,"reusedWorkspace":true,"sentToExistingSession":false,"retryToken":"t2"}"#)])
        var req = makeRequest(exe: "/bin/x", localPath: "/repo")
        req.retryToken = "t1"
        let res = try await ScriptLauncher(runner: runner).launch(req)
        #expect(res.workspaceRef == "/w" && res.reusedWorkspace && res.terminalHandle == nil && res.retryToken == "t2")
        let c = runner.calls[0]
        #expect(c.executable == "/bin/x" && c.arguments == ["launch"] && c.timeout == 120)
        #expect(c.environment == ["PILOTBOAT_RUN_ID": req.runId.uuidString])
        let json = try stdinJSON(c)
        #expect(json["version"] as? Int == 1)
        #expect(json["prompt"] as? String == "review it")
        #expect((json["repository"] as! [String: Any])["launcherBinding"] as? String == "/repo")
        #expect(json["workspacePolicy"] as? String == "alwaysNew")
        #expect(json["retryToken"] as? String == "t1")
    }

    @Test func v1RequestKeepsTheFieldsCoreUsedToEncode() throws {
        var req = makeRequest(exe: "/bin/x", binding: "/b")
        req.previousWorkspaceRef = "/prev"; req.previousTerminalHandle = "term"; req.retryToken = "t"
        var dto = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ScriptLaunchRequestV1(req))) as! [String: Any]
        let core = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        #expect(dto.removeValue(forKey: "version") as? Int == 1)
        #expect(NSDictionary(dictionary: dto) == NSDictionary(dictionary: core))
    }

    @Test func resultWithoutOptionalFieldsDecodes() async throws {
        let res = try await ScriptLauncher(runner: fake([ok(#"{"workspaceRef":"/w"}"#)])).launch(makeRequest(exe: "/bin/x"))
        #expect(res.workspaceRef == "/w" && !res.reusedWorkspace && !res.sentToExistingSession && res.retryToken == nil && res.terminalHandle == nil)
    }

    @Test func settingsRoundTrip() {
        let s = ScriptSettings(json: .object(["executable": .string("/bin/x"), "localPath": .string("/r"), "other": .bool(true)]))
        #expect(s.executable == "/bin/x" && s.localPath == "/r")
        #expect(s.json() == .object(["executable": .string("/bin/x"), "localPath": .string("/r")]))
        #expect(ScriptSettings(json: .object(["executable": .number(1)])).executable == nil)
        #expect(ScriptSettings(json: .object(["executable": .string("")])).resolvedExecutable == nil)
    }

    @Test func failureCarriesStderrTail() async throws {
        let err = String(repeating: "a", count: 5000) + "END"
        let runner = fake([CommandResult(exitCode: 3, stdout: Data(), stderr: Data(err.utf8))])
        do { _ = try await ScriptLauncher(runner: runner).launch(makeRequest(exe: "/bin/x")); Issue.record("no throw") }
        catch let ScriptLauncherError.failed(code, tail) { #expect(code == 3 && tail.count == 4096 && tail.hasSuffix("END")) }
    }

    @Test func timeoutAndInvalidJSON() async throws {
        let t = fake([CommandResult(exitCode: 15, stdout: Data(), stderr: Data(), timedOut: true)])
        await #expect(throws: ScriptLauncherError.timedOut) { try await ScriptLauncher(runner: t).launch(makeRequest(exe: "/bin/x")) }
        let b = fake([ok("nope")])
        await #expect(throws: ScriptLauncherError.invalidOutput("nope")) { try await ScriptLauncher(runner: b).launch(makeRequest(exe: "/bin/x")) }
    }

    @Test func errorsHaveDescriptions() {
        #expect(ScriptLauncherError.failed(exitCode: 2, stderrTail: "boom").localizedDescription == "The launcher script exited with code 2.\nboom")
        #expect(ScriptLauncherError.timedOut.localizedDescription == "The launcher script timed out.")
    }

    @Test func missingExecutable() async {
        await #expect(throws: ScriptLauncherError.missingExecutable) { try await ScriptLauncher(runner: fake([])).launch(makeRequest(exe: "")) }
    }

    @Test func bindingWinsOverLocalPath() async throws {
        let runner = fake([ok(#"{"workspaceRef":"/w"}"#)])
        _ = try await ScriptLauncher(runner: runner).launch(makeRequest(exe: "/bin/x", localPath: "/a", binding: "/b"))
        let json = try stdinJSON(runner.calls[0])
        #expect((json["repository"] as! [String: Any])["launcherBinding"] as? String == "/b")
        #expect(((json["launcherSettings"] as! [String: Any])["localPath"]) as? String == "/a")
    }

    @Test func capabilitiesDecodeAndCachePerExecutable() async {
        let runner = fake([ok(#"{"reuseWorkspace": true, "sendToSession": false}"#)])
        let l = ScriptLauncher(runner: runner)
        #expect(await l.capabilities(settings: .object([:])).isEmpty)
        #expect(await l.capabilities(settings: .object(["executable": .string("/bin/x")])) == [.reuseWorkspace])
        _ = await l.capabilities(executable: "/bin/x")
        #expect(runner.calls.count == 1 && runner.calls[0].arguments == ["capabilities"])
    }

    @Test func cachedCapabilitiesStayStaleWhenTheScriptChanges() async {
        let runner = fake([ok(#"{"reuseWorkspace": false, "sendToSession": false}"#), ok(#"{"reuseWorkspace": true, "sendToSession": true}"#)])
        let l = ScriptLauncher(runner: runner)
        #expect(await l.capabilities(executable: "/bin/x").isEmpty)
        #expect(await l.capabilities(executable: "/bin/x").isEmpty)
        #expect(runner.calls.count == 1)
        #expect(await ScriptLauncher(runner: runner).capabilities(executable: "/bin/x") == [.reuseWorkspace, .sendToSession])
    }

    @Test func failedCapabilitiesQueryIsNotCached() async {
        let runner = fake([CommandResult(exitCode: 1, stdout: Data(), stderr: Data()), ok(#"{"reuseWorkspace": true, "sendToSession": true}"#)])
        let l = ScriptLauncher(runner: runner)
        #expect(await l.capabilities(executable: "/bin/x").isEmpty)
        #expect(await l.capabilities(executable: "/bin/x") == [.reuseWorkspace, .sendToSession])
        #expect(runner.calls.count == 2)
    }

    @Test func describeTruncatesPrompt() async {
        let d = await ScriptLauncher(runner: fake([])).describe(makeRequest(exe: "/bin/x", prompt: String(repeating: "p", count: 500)))
        #expect(d.hasPrefix("/bin/x launch\n") && !d.contains(String(repeating: "p", count: 201)) && d.contains(String(repeating: "p", count: 200)))
    }

    @Test func openAndDiagnose() async throws {
        let runner = FakeCommandRunner(rules: [(["/bin/sh", "diagnose"], ok("all good\nsecond")), (["/bin/x", "open"], ok(""))])
        let l = ScriptLauncher(runner: runner)
        let good = await l.diagnose(settings: .object(["executable": .string("/bin/sh")]))
        #expect(good.count == 1 && good[0].level == .ok && good[0].detail == "all good")
        #expect(await l.diagnose(settings: .object(["executable": .string("/nonexistent/x")])).map(\.level) == [.error])
        #expect(await l.diagnose(settings: .object([:])).map(\.level) == [.error])
        await #expect(throws: ScriptLauncherError.missingExecutable) { try await l.open("/w", settings: .object([:])) }
        try await l.open("/w", settings: .object(["executable": .string("/bin/x")]))
        #expect(runner.calls.last!.executable == "/bin/x")
        #expect(runner.calls.last!.arguments == ["open", "/w"])
        #expect(runner.calls.last!.timeout == 30)
    }

    @Test func openTimeout() async {
        let runner = fake([CommandResult(exitCode: 15, stdout: Data(), stderr: Data(), timedOut: true)])
        await #expect(throws: ScriptLauncherError.timedOut) {
            try await ScriptLauncher(runner: runner).open("/w", settings: ScriptSettings(executable: "/bin/x").json())
        }
    }
}

@Suite struct IntegrationTests {
    func script(_ dir: URL, _ name: String, _ body: String) throws -> String {
        let u = dir.appendingPathComponent(name)
        try "#!/bin/bash\n\(body)\n".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u.path
    }
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func scriptsEndToEnd() async throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let l = ScriptLauncher(runner: DryRunRunner())
        let good = try script(d, "good", #"cat >/dev/null; echo "{\"workspaceRef\":\"$PILOTBOAT_RUN_ID\",\"reusedWorkspace\":false,\"sentToExistingSession\":false}""#)
        let req = makeRequest(exe: good)
        #expect(try await l.launch(req).workspaceRef == req.runId.uuidString)
        let bad = try script(d, "bad", "cat >/dev/null; echo boom >&2; exit 4")
        do { _ = try await l.launch(makeRequest(exe: bad)); Issue.record("no throw") }
        catch let ScriptLauncherError.failed(code, tail) { #expect(code == 4 && tail == "boom\n") }
        let junk = try script(d, "junk", "cat >/dev/null; echo not-json")
        await #expect(throws: ScriptLauncherError.invalidOutput("not-json\n")) { try await l.launch(makeRequest(exe: junk)) }
    }

    @Test func timeoutMapsToTimedOut() async throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let slow = try script(d, "slow", "sleep 30")
        let r = try await DryRunRunner().run(Command(slow, ["launch"], timeout: 0.3))
        #expect(r.timedOut)
    }

    @Test func scriptEnvironment() async throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let envFile = d.appendingPathComponent("env").path
        let exe = try script(d, "env", #"cat >/dev/null; env > "\#(envFile)"; echo '{"workspaceRef":"/w"}'"#)
        let req = makeRequest(exe: exe)
        _ = try await ScriptLauncher(runner: DryRunRunner()).launch(req)
        let lines = try String(contentsOfFile: envFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.contains("PILOTBOAT_RUN_ID=\(req.runId.uuidString)"))
        #expect(lines.contains { $0.hasPrefix("PATH=") })
        #expect(!lines.contains { $0.hasPrefix("GH_TOKEN=") || $0.hasPrefix("GITHUB_TOKEN=") })
    }

    @Test func sampleScriptCreatesWorktree() async throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let origin = d.appendingPathComponent("origin").path
        let repo = d.appendingPathComponent("myrepo").path
        func sh(_ args: [String], cwd: String? = nil) throws -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            p.environment = ProcessInfo.processInfo.environment.merging(["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]) { $1 }
            let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
            try p.run(); let data = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            #expect(p.terminationStatus == 0)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try FileManager.default.createDirectory(atPath: origin, withIntermediateDirectories: true)
        _ = try sh(["git", "init", "-q", "-b", "main"], cwd: origin)
        _ = try sh(["git", "commit", "-q", "--allow-empty", "-m", "init"], cwd: origin)
        _ = try sh(["git", "checkout", "-q", "-b", "feature"], cwd: origin)
        _ = try sh(["git", "commit", "-q", "--allow-empty", "-m", "feat"], cwd: origin)
        let sha = try sh(["git", "rev-parse", "HEAD"], cwd: origin)
        _ = try sh(["git", "checkout", "-q", "main"], cwd: origin)
        _ = try sh(["git", "clone", "-q", origin, repo])

        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let exe = url.appendingPathComponent("contrib/launchers/git-worktree-terminal").path
        let l = ScriptLauncher(runner: DryRunRunner())
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        #expect(await l.capabilities(executable: exe) == [.reuseWorkspace])

        let new = try await l.launch(makeRequest(exe: exe, localPath: repo, policy: .alwaysNew, prompt: "it's \"quoted\" $(x)", headSHA: sha))
        #expect(real(new.workspaceRef) == real(d.appendingPathComponent("myrepo-worktrees/pr-7-review").path) && !new.reusedWorkspace)
        #expect(try sh(["git", "rev-parse", "HEAD"], cwd: new.workspaceRef) == sha)

        let created = try await l.launch(makeRequest(exe: exe, localPath: repo, policy: .reuseOrCreate, headRef: "feature"))
        #expect(real(created.workspaceRef) == real(d.appendingPathComponent("myrepo-worktrees/pr-7").path) && !created.reusedWorkspace)
        let reused = try await l.launch(makeRequest(exe: exe, localPath: repo, policy: .reuseOrCreate, headRef: "feature"))
        #expect(real(reused.workspaceRef) == real(created.workspaceRef) && reused.reusedWorkspace)

        _ = try sh(["git", "checkout", "-q", "feature"], cwd: origin)
        _ = try sh(["git", "commit", "-q", "--allow-empty", "-m", "feat 2"], cwd: origin)
        let sha2 = try sh(["git", "rev-parse", "HEAD"], cwd: origin)
        var again = makeRequest(exe: exe, localPath: repo, policy: .reusePrevious, headSHA: sha2)
        again.previousWorkspaceRef = new.workspaceRef
        let continued = try await l.launch(again)
        #expect(real(continued.workspaceRef) == real(new.workspaceRef) && continued.reusedWorkspace)
        #expect(try sh(["git", "rev-parse", "HEAD"], cwd: continued.workspaceRef) == sha2)

        again.previousWorkspaceRef = d.appendingPathComponent("gone").path
        let fresh = try await l.launch(again)
        #expect(real(fresh.workspaceRef) == real(d.appendingPathComponent("myrepo-worktrees/pr-7-review-2").path) && !fresh.reusedWorkspace)
    }
}
