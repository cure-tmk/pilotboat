import Foundation
import os
import ProcessKit

struct Git: Sendable {
    let runner: any CommandRunner
    private static let logger = Logger(subsystem: "io.github.cure-tmk.pilotboat", category: "orca")

    static func fetch(path: String, ref: String) -> [String] { ["git", "-C", path, "fetch", "origin", ref] }
    static func ffMerge(path: String, to target: String) -> [String] { ["git", "-C", path, "merge", "--ff-only", target] }
    static func isAncestor(path: String, _ a: String, _ b: String) -> [String] { ["git", "-C", path, "merge-base", "--is-ancestor", a, b] }
    static func upstream(path: String) -> [String] { ["git", "-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"] }
    static func setUpstream(path: String, ref: String) -> [String] { ["git", "-C", path, "branch", "--set-upstream-to=origin/\(ref)"] }

    func fetch(path: String, ref: String) async throws { try await check(Self.fetch(path: path, ref: ref)) }

    /// `ok` is false (and logged) when the fast-forward is not possible; `errorTail` is git's stderr tail.
    func ffMerge(path: String, to target: String) async throws -> (ok: Bool, errorTail: String) {
        let r = try await run(Self.ffMerge(path: path, to: target))
        if !r.succeeded { Self.logger.notice("Fast-forward of \(path, privacy: .public) to \(target, privacy: .public) failed: \(r.errorTail, privacy: .public)") }
        return (r.succeeded, r.errorTail)
    }

    func isAncestor(path: String, _ a: String, _ b: String) async throws -> Bool {
        let r = try await run(Self.isAncestor(path: path, a, b))
        switch r.exitCode {
        case 0: return true
        case 1: return false
        default: throw OrcaLauncherError.commandFailed(r.errorTail)
        }
    }

    func hasUpstream(path: String) async throws -> Bool { try await run(Self.upstream(path: path)).succeeded }

    func setUpstream(path: String, ref: String) async throws { try await check(Self.setUpstream(path: path, ref: ref)) }

    private func run(_ argv: [String]) async throws -> CommandResult { try await runner.run(Command(argv[0], Array(argv.dropFirst()))) }

    private func check(_ argv: [String]) async throws {
        let r = try await run(argv)
        guard r.succeeded else { throw OrcaLauncherError.commandFailed(r.errorTail) }
    }
}
