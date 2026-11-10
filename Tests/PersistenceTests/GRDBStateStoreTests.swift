import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func pr(_ n: Int = 1) -> PullRequestRef {
    PullRequestRef(host: "github.com", repo: "o/r", number: n, url: URL(string: "https://github.com/o/r/pull/\(n)")!, title: "t", headRef: "h", headSHA: "s", baseRef: "main", isDraft: false, isCrossRepository: false, labels: ["a"], author: "me")
}

private func event(_ key: String, at: Date = t0, kind: EventKind = .reviewSubmitted) -> Event {
    Event(kind: kind, repo: "o/r", subject: .pullRequest(pr()), actor: Actor(login: "x", isBot: false), occurredAt: at, dedupeKey: key, review: ReviewInfo(id: 1, state: "APPROVED"))
}

private func run(_ state: RunState = .settling, rule: String = "r1", number: Int = 1, created: Date = t0) -> Run {
    Run(state: state, ruleId: rule, repo: "o/r", prNumber: number, createdAt: created, updatedAt: created)
}

@Test func processedEventsAndPurge() throws {
    let s = try GRDBStateStore()
    try s.write { a in
        #expect(try !a.hasProcessed(dedupeKey: "k"))
        try a.markProcessed(event("k"), seenAt: t0)
        try a.markProcessed(event("k"), seenAt: t0)
        try a.markProcessed(event("k2"), seenAt: t0.addingTimeInterval(100))
    }
    try s.write { a in
        #expect(try a.hasProcessed(dedupeKey: "k"))
        try a.purgeProcessedEvents(before: t0.addingTimeInterval(50))
        #expect(try !a.hasProcessed(dedupeKey: "k"))
        #expect(try a.hasProcessed(dedupeKey: "k2"))
    }
}

@Test func runRoundTrip() throws {
    let s = try GRDBStateStore()
    var r = run(.launched)
    r.skipReason = .userSkipped
    r.settleUntil = t0.addingTimeInterval(5.5)
    r.snapshot = RunSnapshot(launcherId: "orca", workspacePolicy: .reuseOrCreate, renderedPrompt: "p", subject: .pullRequest(pr()))
    r.workspaceRef = "w"; r.terminalHandle = "t"; r.retryToken = "tok"; r.error = "e"
    r.launchedAt = t0.addingTimeInterval(1)
    try s.write { try $0.insertRun(r) }
    #expect(try s.read { try $0.run(id: r.id) } == r)
    r.state = .failed; r.error = "boom"
    try s.write { try $0.updateRun(r) }
    #expect(try s.read { try $0.run(id: r.id) } == r)
    #expect(try s.read { try $0.runs(state: .failed) } == [r])
    #expect(try s.read { try $0.runs(state: .queued) }.isEmpty)
    #expect(try s.read { try $0.run(id: UUID()) } == nil)
}

@Test func recentSettlingLatestWorkspace() throws {
    let s = try GRDBStateStore()
    var a = run(.launched, rule: "a", created: t0); a.workspaceRef = "wa"
    var b = run(.launched, rule: "b", created: t0.addingTimeInterval(10)); b.workspaceRef = "wb"
    let c = run(.settling, rule: "c", created: t0.addingTimeInterval(20))
    let other = run(.launched, number: 2, created: t0.addingTimeInterval(30))
    try s.write { x in for r in [a, b, c, other] { try x.insertRun(r) } }
    try s.read { (x: any StateAccess) throws in
        #expect(try x.recentRuns(limit: 3).map(\.id) == [other.id, c.id, b.id])
        #expect(try x.settlingRun(ruleId: "c", repo: "o/r", prNumber: 1)?.id == c.id)
        #expect(try x.settlingRun(ruleId: "a", repo: "o/r", prNumber: 1) == nil)
        #expect(try x.latestRunWithWorkspace(repo: "o/r", prNumber: 1)?.id == b.id)
        #expect(try x.latestRunWithWorkspace(repo: "o/r", prNumber: 2) == nil)
    }
}

@Test func countLaunchedBoundary() throws {
    let s = try GRDBStateStore()
    var before = run(.launched, rule: "a"); before.launchedAt = t0.addingTimeInterval(-1)
    var at = run(.launched, rule: "b"); at.launchedAt = t0
    var queued = run(.queued, rule: "c"); queued.launchedAt = t0
    try s.write { x in for r in [before, at, queued] { try x.insertRun(r) } }
    #expect(try s.read { try $0.countLaunched(since: t0) } == 1)
    #expect(try s.read { try $0.countLaunched(since: t0.addingTimeInterval(1)) } == 0)
}

@Test func attachAndEvents() throws {
    let s = try GRDBStateStore()
    let r = run()
    let e1 = event("e1", at: t0), e2 = event("e2", at: t0.addingTimeInterval(1))
    try s.write { a in
        try a.insertRun(r)
        try a.attach(e2, toRun: r.id)
        try a.attach(e1, toRun: r.id)
    }
    #expect(try s.read { try $0.events(forRun: r.id) } == [e1, e2])
    #expect(throws: (any Error).self) { try s.write { try $0.attach(e1, toRun: r.id) } }
}

@Test func baselinesAndCursors() throws {
    let s = try GRDBStateStore()
    let id = UUID()
    try s.write { a in
        #expect(try !a.hasAnyBaseline())
        #expect(try a.baseline(repoId: id, kind: .reviewRequested) == nil)
        try a.setBaseline(repoId: id, kind: .reviewRequested, at: t0)
        try a.setBaseline(repoId: id, kind: .reviewRequested, at: t0.addingTimeInterval(1))
        #expect(try a.hasAnyBaseline())
        #expect(try a.baseline(repoId: id, kind: .reviewRequested) == t0.addingTimeInterval(1))
        #expect(try a.baseline(repoId: id, kind: .reviewSubmitted) == nil)
        #expect(try a.cursor(sourceType: "github") == nil)
        try a.setCursor(sourceType: "github", t0)
        try a.setCursor(sourceType: "github", t0.addingTimeInterval(2))
        #expect(try a.cursor(sourceType: "github") == t0.addingTimeInterval(2))
    }
}

@Test func writeRollsBackOnThrow() throws {
    struct Boom: Error {}
    let s = try GRDBStateStore()
    let r = run()
    #expect(throws: Boom.self) {
        try s.write { a in try a.insertRun(r); throw Boom() }
    }
    #expect(try s.read { try $0.run(id: r.id) } == nil)
}

@Test func secondSettlingRunRejected() throws {
    let s = try GRDBStateStore()
    try s.write { try $0.insertRun(run(.settling)) }
    #expect(throws: DatabaseError.self) { try s.write { try $0.insertRun(run(.settling)) } }
    try s.write { try $0.insertRun(run(.queued)) }
    try s.write { try $0.insertRun(run(.settling, rule: "other")) }
}

@Test func fileBackedPersists() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("state.sqlite")
    let r = run()
    try GRDBStateStore(url: url).write { try $0.insertRun(r) }
    #expect(try GRDBStateStore(url: url).read { try $0.run(id: r.id) } == r)
}

@Test func unknownRunStateThrowsInsteadOfCrashing() throws {
    let r = run(.queued)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("state.sqlite")
    try GRDBStateStore(url: url).write { try $0.insertRun(r) }
    try DatabaseQueue(path: url.path).write { try $0.execute(sql: "UPDATE runs SET state = 'paused'") }
    let store = try GRDBStateStore(url: url)
    #expect(throws: CorruptRowError(column: "state", value: "paused")) { try store.read { try $0.run(id: r.id) } }
}

@Test func runsCreatedIndexExists() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("state.sqlite")
    _ = try GRDBStateStore(url: url)
    #expect(try DatabaseQueue(path: url.path).read { try $0.indexes(on: "runs").map(\.name) }.contains("runs_created"))
}
