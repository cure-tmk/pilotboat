import Core
import Foundation
import ProcessKit
import Testing
@testable import LauncherScript

final class FakeRunner: CommandRunner, @unchecked Sendable {
    let lock = NSLock()
    var commands: [Command] = []
    var result: CommandResult
    init(_ result: CommandResult) { self.result = result }
    func run(_ command: Command) async throws -> CommandResult {
        lock.withLock { commands.append(command) }
        return result
    }
}

struct ProcessRunner: CommandRunner {
    func run(_ c: Command) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { k in
            DispatchQueue.global().async { k.resume(with: Result { try Self.runSync(c) }) }
        }
    }

    static func runSync(_ c: Command) throws -> CommandResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pbrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (inURL, outURL, errURL) = (dir.appendingPathComponent("in"), dir.appendingPathComponent("out"), dir.appendingPathComponent("err"))
        try (c.stdin ?? Data()).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.executable)
        p.arguments = c.arguments
        p.environment = ProcessInfo.processInfo.environment.merging(c.environment ?? [:]) { $1 }
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        p.standardError = try FileHandle(forWritingTo: errURL)
        try p.run()
        let deadline = Date().addingTimeInterval(c.timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline { timedOut = true; p.terminate(); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        p.waitUntilExit()
        return CommandResult(exitCode: p.terminationStatus, stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL), timedOut: timedOut)
    }
}

func ok(_ s: String) -> CommandResult { CommandResult(exitCode: 0, stdout: Data(s.utf8), stderr: Data()) }

func makeRequest(exe: String, localPath: String? = nil, policy: WorkspacePolicy = .alwaysNew, prompt: String = "review it", headRef: String = "feature", headSHA: String = "abc", binding: String? = nil) -> LaunchRequest {
    var settings: [String: JSONValue] = ["executable": .string(exe)]
    if let localPath { settings["localPath"] = .string(localPath) }
    let pr = PullRequestRef(host: "github.com", repo: "o/r", number: 7, url: URL(string: "https://github.com/o/r/pull/7")!, title: "t", headRef: headRef, headSHA: headSHA, baseRef: "main", isDraft: false, isCrossRepository: false, labels: [], author: "a")
    return LaunchRequest(runId: UUID(), subject: .pullRequest(pr), repository: RepositoryInfo(host: "github.com", fullName: "o/r", launcherBinding: binding), workspacePolicy: policy, prompt: prompt, launcherSettings: .object(settings))
}

@Suite struct FakeRunnerTests {
    @Test func launchBuildsCommandAndDecodes() async throws {
        let fake = FakeRunner(ok(#"{"workspaceRef":"/w","terminalHandle":null,"reusedWorkspace":true,"sentToExistingSession":false,"retryToken":"t2"}"#))
        var req = makeRequest(exe: "/bin/x", localPath: "/repo")
        req.retryToken = "t1"
        let res = try await ScriptLauncher(runner: fake).launch(req)
        #expect(res.workspaceRef == "/w" && res.reusedWorkspace && res.terminalHandle == nil && res.retryToken == "t2")
        let c = fake.commands[0]
        #expect(c.executable == "/bin/x" && c.arguments == ["launch"] && c.timeout == 120)
        #expect(c.environment == ["PILOTBOAT_RUN_ID": req.runId.uuidString])
        let json = try JSONSerialization.jsonObject(with: c.stdin!) as! [String: Any]
        #expect(json["prompt"] as? String == "review it")
        #expect((json["repository"] as! [String: Any])["launcherBinding"] as? String == "/repo")
        #expect(json["workspacePolicy"] as? String == "alwaysNew")
        #expect(json["retryToken"] as? String == "t1")
    }

    @Test func failureCarriesStderrTail() async throws {
        let err = String(repeating: "a", count: 5000) + "END"
        let fake = FakeRunner(CommandResult(exitCode: 3, stdout: Data(), stderr: Data(err.utf8)))
        do { _ = try await ScriptLauncher(runner: fake).launch(makeRequest(exe: "/bin/x")); Issue.record("no throw") }
        catch let ScriptLauncherError.failed(code, tail) { #expect(code == 3 && tail.count == 4096 && tail.hasSuffix("END")) }
    }

    @Test func timeoutAndInvalidJSON() async throws {
        let t = FakeRunner(CommandResult(exitCode: 15, stdout: Data(), stderr: Data(), timedOut: true))
        await #expect(throws: ScriptLauncherError.timedOut) { try await ScriptLauncher(runner: t).launch(makeRequest(exe: "/bin/x")) }
        let b = FakeRunner(ok("nope"))
        await #expect(throws: ScriptLauncherError.invalidOutput("nope")) { try await ScriptLauncher(runner: b).launch(makeRequest(exe: "/bin/x")) }
    }

    @Test func missingExecutable() async {
        await #expect(throws: ScriptLauncherError.missingExecutable) { try await ScriptLauncher(runner: FakeRunner(ok(""))).launch(makeRequest(exe: "")) }
    }

    @Test func localPathFallsBackIntoBinding() async throws {
        let fake = FakeRunner(ok(#"{"workspaceRef":"/w","reusedWorkspace":false,"sentToExistingSession":false}"#))
        _ = try await ScriptLauncher(runner: fake).launch(makeRequest(exe: "/bin/x", localPath: "/a", binding: "/b"))
        let json = try JSONSerialization.jsonObject(with: fake.commands[0].stdin!) as! [String: Any]
        #expect((json["repository"] as! [String: Any])["launcherBinding"] as? String == "/b")
        #expect(((json["launcherSettings"] as! [String: Any])["localPath"]) as? String == "/a")
    }

    @Test func capabilitiesDecodeAndUnion() async {
        let fake = FakeRunner(ok(#"{"reuseWorkspace": true, "sendToSession": false}"#))
        let l = ScriptLauncher(runner: fake)
        #expect(l.capabilities.isEmpty)
        #expect(await l.capabilities(executable: "/bin/x") == [.reuseWorkspace])
        #expect(l.capabilities == [.reuseWorkspace])
        _ = await l.capabilities(executable: "/bin/x")
        #expect(fake.commands.count == 1 && fake.commands[0].arguments == ["capabilities"])
    }

    @Test func describeTruncatesPrompt() async {
        let d = await ScriptLauncher(runner: FakeRunner(ok(""))).describe(makeRequest(exe: "/bin/x", prompt: String(repeating: "p", count: 500)))
        #expect(d.hasPrefix("/bin/x launch\n") && !d.contains(String(repeating: "p", count: 201)) && d.contains(String(repeating: "p", count: 200)))
    }

    @Test func openAndDiagnose() async throws {
        let fake = FakeRunner(ok("all good\nsecond"))
        let l = ScriptLauncher(runner: fake)
        let good = await l.diagnose(settings: .object(["executable": .string("/bin/sh")]))
        #expect(good.count == 1 && good[0].level == .ok && good[0].detail == "all good")
        #expect(await l.diagnose(settings: .object(["executable": .string("/nonexistent/x")])).map(\.level) == [.error])
        #expect(await l.diagnose(settings: .object([:])).map(\.level) == [.error])
        await #expect(throws: ScriptLauncherError.missingExecutable) { try await l.open("/w", settings: .object([:])) }
        try await l.open("/w", settings: .object(["executable": .string("/bin/x")]))
        #expect(fake.commands.last!.executable == "/bin/x")
        #expect(fake.commands.last!.arguments == ["open", "/w"])
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
        let l = ScriptLauncher(runner: ProcessRunner())
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
        let r = try await ProcessRunner().run(Command(slow, ["launch"], timeout: 0.3))
        #expect(r.timedOut)
        await #expect(throws: ScriptLauncherError.timedOut) {
            try await ScriptLauncher(runner: TimeoutRunner()).launch(makeRequest(exe: slow))
        }
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
        let l = ScriptLauncher(runner: ProcessRunner())
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        #expect(await l.capabilities(executable: exe) == [.reuseWorkspace])

        setenv("PILOTBOAT_DRY_RUN", "1", 1)
        let new = try await l.launch(makeRequest(exe: exe, localPath: repo, policy: .alwaysNew, prompt: "it's \"quoted\" $(x)", headSHA: sha))
        #expect(real(new.workspaceRef) == real(d.appendingPathComponent("myrepo-worktrees/pr-7-review").path) && !new.reusedWorkspace)
        #expect(try sh(["git", "rev-parse", "HEAD"], cwd: new.workspaceRef) == sha)

        let created = try await l.launch(makeRequest(exe: exe, localPath: repo, policy: .reuseOrCreate, headRef: "feature"))
        #expect(real(created.workspaceRef) == real(d.appendingPathComponent("myrepo-worktrees/pr-7").path) && !created.reusedWorkspace)
        let reused = try await l.launch(makeRequest(exe: exe, localPath: repo, policy: .reuseOrCreate, headRef: "feature"))
        #expect(real(reused.workspaceRef) == real(created.workspaceRef) && reused.reusedWorkspace)
    }
}

struct TimeoutRunner: CommandRunner {
    func run(_ c: Command) async throws -> CommandResult { CommandResult(exitCode: 15, stdout: Data(), stderr: Data(), timedOut: true) }
}
