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
        #expect(await fake.recorded.map(\.executable) == ["git"])
    }
}
