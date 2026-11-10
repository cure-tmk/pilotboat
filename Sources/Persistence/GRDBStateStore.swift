import Core
import Foundation
import GRDB

/// A stored value this version cannot read, e.g. a run state written by a newer app.
public struct CorruptRowError: Error, Hashable, Sendable {
    public var column: String
    public var value: String
}

public final class GRDBStateStore: StateStore, @unchecked Sendable {
    private let queue: DatabaseQueue

    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(queue)
    }

    public init() throws {
        queue = try DatabaseQueue()
        try Self.migrator.migrate(queue)
    }

    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(path: url.path)
    }

    public func read<T>(_ body: (any StateAccess) throws -> T) throws -> T {
        try queue.read { try body(Access(db: $0)) }
    }

    public func write<T>(_ body: (any StateAccess) throws -> T) throws -> T {
        try queue.write { try body(Access(db: $0)) }
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE processed_events (
                dedupe_key TEXT PRIMARY KEY, kind TEXT NOT NULL, repo TEXT NOT NULL,
                pr_number INTEGER, seen_at REAL NOT NULL);
            CREATE INDEX processed_events_seen_at ON processed_events(seen_at);
            CREATE TABLE runs (
                id TEXT PRIMARY KEY, rule_id TEXT NOT NULL, repo TEXT NOT NULL, pr_number INTEGER NOT NULL,
                state TEXT NOT NULL, skip_reason TEXT, settle_until REAL, snapshot_json TEXT,
                workspace_ref TEXT, terminal_handle TEXT, retry_token TEXT, error TEXT,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, launched_at REAL);
            CREATE UNIQUE INDEX runs_one_settling ON runs(rule_id, repo, pr_number) WHERE state = 'settling';
            CREATE INDEX runs_state ON runs(state);
            CREATE INDEX runs_pr ON runs(repo, pr_number, created_at);
            CREATE TABLE run_events (
                dedupe_key TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                occurred_at REAL NOT NULL, event_json TEXT NOT NULL);
            CREATE INDEX run_events_run ON run_events(run_id);
            CREATE TABLE baselines (
                repo_id TEXT NOT NULL, kind TEXT NOT NULL, at REAL NOT NULL, PRIMARY KEY (repo_id, kind));
            CREATE TABLE source_cursors (source_type TEXT PRIMARY KEY, cursor REAL NOT NULL);
            """)
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: "CREATE INDEX runs_created ON runs(created_at)")
        }
        return m
    }
}

private func ts(_ d: Date?) -> Double? { d?.timeIntervalSince1970 }
private func date(_ t: Double?) -> Date? { t.map(Date.init(timeIntervalSince1970:)) }

private func json<T: Encodable>(_ v: T) throws -> String {
    String(decoding: try JSONEncoder().encode(v), as: UTF8.self)
}

private func unjson<T: Decodable>(_ s: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(s.utf8))
}

private struct Access: StateAccess {
    let db: Database

    func hasProcessed(dedupeKey: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM processed_events WHERE dedupe_key = ?)", arguments: [dedupeKey]) ?? false
    }

    func markProcessed(_ event: Event, seenAt: Date) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO processed_events (dedupe_key, kind, repo, pr_number, seen_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [event.dedupeKey, event.kind.rawValue, event.repo, event.subject.pullRequest?.number, seenAt.timeIntervalSince1970])
    }

    func purgeProcessedEvents(before: Date) throws {
        try db.execute(sql: "DELETE FROM processed_events WHERE seen_at < ?", arguments: [before.timeIntervalSince1970])
    }

    func insertRun(_ r: Run) throws {
        try db.execute(sql: """
            INSERT INTO runs (id, rule_id, repo, pr_number, state, skip_reason, settle_until, snapshot_json,
                workspace_ref, terminal_handle, retry_token, error, created_at, updated_at, launched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: StatementArguments(try args(r)))
    }

    func updateRun(_ r: Run) throws {
        let a = try args(r)
        try db.execute(sql: """
            UPDATE runs SET rule_id = ?, repo = ?, pr_number = ?, state = ?, skip_reason = ?, settle_until = ?,
                snapshot_json = ?, workspace_ref = ?, terminal_handle = ?, retry_token = ?, error = ?,
                created_at = ?, updated_at = ?, launched_at = ? WHERE id = ?
            """, arguments: StatementArguments(Array(a.dropFirst()) + [r.id.uuidString]))
    }

    func run(id: UUID) throws -> Run? {
        try fetchRuns("WHERE id = ?", [id.uuidString]).first
    }

    func runs(state: RunState) throws -> [Run] {
        try fetchRuns("WHERE state = ? ORDER BY created_at", [state.rawValue])
    }

    func recentRuns(limit: Int) throws -> [Run] {
        try fetchRuns("ORDER BY created_at DESC, rowid DESC LIMIT ?", [limit])
    }

    func settlingRun(ruleId: String, repo: String, prNumber: Int) throws -> Run? {
        try fetchRuns("WHERE state = 'settling' AND rule_id = ? AND repo = ? AND pr_number = ?", [ruleId, repo, prNumber]).first
    }

    func latestRunWithWorkspace(repo: String, prNumber: Int) throws -> Run? {
        try fetchRuns("WHERE repo = ? AND pr_number = ? AND workspace_ref IS NOT NULL ORDER BY created_at DESC, rowid DESC LIMIT 1", [repo, prNumber]).first
    }

    func countLaunched(since: Date) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs WHERE state = 'launched' AND launched_at >= ?", arguments: [since.timeIntervalSince1970]) ?? 0
    }

    func attach(_ event: Event, toRun runId: UUID) throws {
        try db.execute(
            sql: "INSERT INTO run_events (dedupe_key, run_id, occurred_at, event_json) VALUES (?, ?, ?, ?)",
            arguments: [event.dedupeKey, runId.uuidString, event.occurredAt.timeIntervalSince1970, try json(event)])
    }

    func events(forRun runId: UUID) throws -> [Event] {
        try String.fetchAll(db, sql: "SELECT event_json FROM run_events WHERE run_id = ? ORDER BY occurred_at, rowid", arguments: [runId.uuidString])
            .map { try unjson($0) }
    }

    func baseline(repoId: UUID, kind: EventKind) throws -> Date? {
        date(try Double.fetchOne(db, sql: "SELECT at FROM baselines WHERE repo_id = ? AND kind = ?", arguments: [repoId.uuidString, kind.rawValue]))
    }

    func setBaseline(repoId: UUID, kind: EventKind, at: Date) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO baselines (repo_id, kind, at) VALUES (?, ?, ?)",
                       arguments: [repoId.uuidString, kind.rawValue, at.timeIntervalSince1970])
    }

    func hasAnyBaseline() throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM baselines)") ?? false
    }

    func cursor(sourceType: String) throws -> Date? {
        date(try Double.fetchOne(db, sql: "SELECT cursor FROM source_cursors WHERE source_type = ?", arguments: [sourceType]))
    }

    func setCursor(sourceType: String, _ d: Date) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO source_cursors (source_type, cursor) VALUES (?, ?)",
                       arguments: [sourceType, d.timeIntervalSince1970])
    }

    private func args(_ r: Run) throws -> [(any DatabaseValueConvertible)?] {
        let snapshot: String? = try r.snapshot.map { try json($0) }
        return [r.id.uuidString, r.ruleId, r.repo, r.prNumber, r.state.rawValue, r.skipReason?.rawValue, ts(r.settleUntil),
                snapshot, r.workspaceRef, r.terminalHandle, r.retryToken, r.error,
                r.createdAt.timeIntervalSince1970, r.updatedAt.timeIntervalSince1970, ts(r.launchedAt)]
    }

    private func fetchRuns(_ tail: String, _ arguments: StatementArguments) throws -> [Run] {
        try Row.fetchAll(db, sql: "SELECT * FROM runs \(tail)", arguments: arguments).map { row in
            let snapshotJSON: String? = row["snapshot_json"]
            let idText: String = row["id"]
            let stateText: String = row["state"]
            let skip: String? = row["skip_reason"]
            guard let id = UUID(uuidString: idText) else { throw CorruptRowError(column: "id", value: idText) }
            guard let state = RunState(rawValue: stateText) else { throw CorruptRowError(column: "state", value: stateText) }
            return Run(
                id: id,
                state: state,
                skipReason: skip.flatMap(SkipReason.init(rawValue:)),
                ruleId: row["rule_id"], repo: row["repo"], prNumber: row["pr_number"],
                settleUntil: date(row["settle_until"]),
                snapshot: try snapshotJSON.map { try unjson($0) },
                workspaceRef: row["workspace_ref"], terminalHandle: row["terminal_handle"],
                retryToken: row["retry_token"], error: row["error"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                launchedAt: date(row["launched_at"]))
        }
    }
}
