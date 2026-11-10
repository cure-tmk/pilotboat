import Foundation
import Testing
@testable import ProcessKit

private let runner = ProcessRunner(searchPath: ["/bin", "/usr/bin"])

@Suite struct ProcessKitTests {
    @Test func echoRoundTrip() async throws {
        let r = try await runner.run(Command("/bin/echo", ["hello", "a b"]))
        #expect(r.succeeded)
        #expect(r.stdoutText == "hello a b\n")
    }

    @Test func bareNameResolvedViaSearchPath() async throws {
        let r = try await runner.run(Command("echo", ["x"]))
        #expect(r.stdoutText == "x\n")
    }

    @Test func stdinPiping() async throws {
        let r = try await runner.run(Command("/bin/cat", stdin: Data("piped".utf8)))
        #expect(r.stdoutText == "piped")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x61, count: 3_000_000).write(to: url)
        let r = try await runner.run(Command("/bin/cat", [url.path], timeout: 20))
        #expect(r.stdout.count == 3_000_000)
    }

    @Test func timeoutKills() async throws {
        let r = try await runner.run(Command("/bin/sleep", ["30"], timeout: 0.5))
        #expect(r.timedOut)
        #expect(!r.succeeded)
        #expect(r.duration < 3)
    }

    @Test func backgroundGrandchildHoldingStdoutDoesNotHang() async throws {
        let r = try await runner.run(Command("/bin/sh", ["-c", "sleep 30 & echo hi"], timeout: 0.5))
        #expect(r.timedOut)
        #expect(r.stdoutText == "hi\n")
        #expect(r.duration < 7)
    }

    @Test func environmentIsAllowlistedAndNeverCarriesGitHubTokens() async throws {
        setenv("GH_TOKEN", "leak", 1); setenv("GITHUB_TOKEN", "leak", 1); setenv("PILOTBOAT_TEST_INHERIT", "yes", 1)
        defer { unsetenv("GH_TOKEN"); unsetenv("GITHUB_TOKEN"); unsetenv("PILOTBOAT_TEST_INHERIT") }
        let keys = ProcessRunner.defaultInheritedKeys.union(["GH_TOKEN", "GITHUB_TOKEN", "PILOTBOAT_TEST_INHERIT"])
        let r = try await ProcessRunner(searchPath: ["/usr/bin"], inheritedKeys: keys)
            .run(Command("/usr/bin/env", environment: ["EXTRA": "1", "GH_TOKEN": "explicit"]))
        let env = Dictionary(uniqueKeysWithValues: r.stdoutText.split(separator: "\n").map { line in
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            return (kv[0], kv.count > 1 ? kv[1] : "")
        })
        #expect(env["GH_TOKEN"] == nil && env["GITHUB_TOKEN"] == nil)
        #expect(env["PILOTBOAT_TEST_INHERIT"] == "yes" && env["EXTRA"] == "1")
        #expect(env["PATH"] == "/usr/bin" && env["HOME"] == NSHomeDirectory())
        let parent = ProcessInfo.processInfo.environment
        for key in ProcessRunner.defaultInheritedKeys { #expect(env[key] == parent[key]) }
        let plain = try await ProcessRunner(searchPath: ["/usr/bin"]).run(Command("/usr/bin/env"))
        #expect(!plain.stdoutText.contains("PILOTBOAT_TEST_INHERIT"))
    }

    @Test func logLineRedactsPromptAndTextValues() {
        let long = String(repeating: "x", count: 300)
        let line = ProcessRunner.loggedArguments(["terminal", "send", "--text", "secret", "--prompt", "also secret", "--model", long])
        #expect(line == "terminal send --text <redacted> --prompt <redacted> --model \(String(repeating: "x", count: 200))")
    }

    @Test func executableNotFound() async {
        await #expect(throws: CommandError.self) {
            try await runner.run(Command("definitely-not-a-command-xyz"))
        }
    }

    @Test func findResolvesLs() {
        #expect(PathResolver.find("ls", in: ["/nonexistent", "/bin"]) == "/bin/ls")
        #expect(PathResolver.find("nope-xyz", in: ["/bin"]) == nil)
    }

    @Test func markerExtraction() {
        let s = "welcome banner\n__PILOTBOAT_BEGIN__/a:/b::/c__PILOTBOAT_END__trailer"
        #expect(PathResolver.extractPath(from: s) == ["/a", "/b", "/c"])
        #expect(PathResolver.extractPath(from: "no markers") == nil)
    }

    @Test func loginShellPathSmoke() async throws {
        try #require(ProcessInfo.processInfo.environment["SHELL"] != nil)
        let path = await PathResolver.loginShellPath()
        #expect(path?.isEmpty == false)
    }

    @Test func resolveDedupes() async {
        let p = await PathResolver.resolve(explicit: ["/bin", "/bin"])
        #expect(p.first == "/bin")
        #expect(p.filter { $0 == "/bin" }.count == 1)
    }

    @Test func fakeRecordsAndAnswers() async throws {
        let fake = FakeCommandRunner(responses: [CommandResult(exitCode: 3, stdout: Data(), stderr: Data())])
        let r = try await fake.run(Command("git", ["status"]))
        #expect(r.exitCode == 3)
        #expect(fake.calls.map(\.executable) == ["git"])
        #expect(try await fake.run(Command("git")).exitCode == 0)
    }

    @Test func fakeMatchesRulesByArgvPrefixOnce() async throws {
        let result = { (code: Int32) in CommandResult(exitCode: code, stdout: Data(), stderr: Data()) }
        let fake = FakeCommandRunner(rules: [(["git", "fetch"], result(1)), (["git"], result(2)), (["git", "fetch"], result(3))])
        #expect(try await fake.run(Command("git", ["fetch", "origin"])).exitCode == 1)
        #expect(try await fake.run(Command("git", ["fetch"])).exitCode == 2)
        #expect(try await fake.run(Command("git", ["fetch"])).exitCode == 3)
        let unscripted = try await fake.run(Command("git", ["fetch"]))
        #expect(unscripted.exitCode == 99 && unscripted.stderrText.hasPrefix("unscripted"))
        #expect(fake.calls.count == 4)
    }

    @Test func fakeHandlerSeesEachCommand() async throws {
        let fake = FakeCommandRunner { CommandResult(exitCode: Int32($0.arguments.count), stdout: Data(), stderr: Data()) }
        #expect(try await fake.run(Command("x", ["a", "b"])).exitCode == 2)
        #expect(fake.calls.map(\.arguments) == [["a", "b"]])
    }
}
