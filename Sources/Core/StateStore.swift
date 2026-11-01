import Foundation

/// Every method runs inside the `read`/`write` scope that handed out the access object.
public protocol StateAccess {
    func hasProcessed(dedupeKey: String) throws -> Bool
    func markProcessed(_ event: Event, seenAt: Date) throws
    func purgeProcessedEvents(before: Date) throws

    func insertRun(_ run: Run) throws
    func updateRun(_ run: Run) throws
    func run(id: UUID) throws -> Run?
    func runs(state: RunState) throws -> [Run]
    /// Newest first.
    func recentRuns(limit: Int) throws -> [Run]
    func settlingRun(ruleId: String, repo: String, prNumber: Int) throws -> Run?
    /// Most recent run for the PR with a `workspaceRef`, newest first.
    func latestRunWithWorkspace(repo: String, prNumber: Int) throws -> Run?
    func countLaunched(since: Date) throws -> Int

    func attach(_ event: Event, toRun runId: UUID) throws
    func events(forRun runId: UUID) throws -> [Event]

    func baseline(repoId: UUID, kind: EventKind) throws -> Date?
    func setBaseline(repoId: UUID, kind: EventKind, at: Date) throws
    func hasAnyBaseline() throws -> Bool

    func cursor(sourceType: String) throws -> Date?
    func setCursor(sourceType: String, _ date: Date) throws
}

public protocol StateStore: Sendable {
    func read<T>(_ body: (any StateAccess) throws -> T) throws -> T
    /// Atomic: either every call inside `body` is persisted or none is.
    func write<T>(_ body: (any StateAccess) throws -> T) throws -> T
}
