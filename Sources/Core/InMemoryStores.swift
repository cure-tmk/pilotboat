import Foundation

public final class InMemoryStateStore: StateStore, @unchecked Sendable {
    struct Tables {
        var processed: [String: Date] = [:]
        var runs: [Run] = []
        var runEvents: [(runId: UUID, event: Event)] = []
        var baselines: [String: Date] = [:]
        var cursors: [String: Date] = [:]
    }

    private let lock = NSLock()
    private var data = Tables()

    public init() {}

    public func read<T>(_ body: (any StateAccess) throws -> T) throws -> T {
        try lock.withLock { try body(Access(data)) }
    }

    public func write<T>(_ body: (any StateAccess) throws -> T) throws -> T {
        try lock.withLock {
            let access = Access(data)
            let result = try body(access)
            data = access.data
            return result
        }
    }

    final class Access: StateAccess {
        var data: Tables
        init(_ data: Tables) { self.data = data }

        private static func baselineKey(_ repoId: UUID, _ kind: EventKind) -> String { "\(repoId)|\(kind.rawValue)" }

        func hasProcessed(dedupeKey: String) throws -> Bool { data.processed[dedupeKey] != nil }
        func markProcessed(_ event: Event, seenAt: Date) throws { data.processed[event.dedupeKey] = seenAt }
        func purgeProcessedEvents(before: Date) throws { data.processed = data.processed.filter { $0.value >= before } }

        func insertRun(_ run: Run) throws { data.runs.append(run) }
        func updateRun(_ run: Run) throws {
            guard let i = data.runs.firstIndex(where: { $0.id == run.id }) else { return }
            data.runs[i] = run
        }
        func run(id: UUID) throws -> Run? { data.runs.first { $0.id == id } }
        func runs(state: RunState) throws -> [Run] { data.runs.filter { $0.state == state } }
        func recentRuns(limit: Int) throws -> [Run] {
            Array(data.runs.enumerated()
                .sorted { ($0.element.createdAt, $0.offset) > ($1.element.createdAt, $1.offset) }
                .prefix(limit).map(\.element))
        }
        func settlingRun(ruleId: String, repo: String, prNumber: Int) throws -> Run? {
            data.runs.first { $0.state == .settling && $0.ruleId == ruleId && $0.repo == repo && $0.prNumber == prNumber }
        }
        func latestRunWithWorkspace(repo: String, prNumber: Int) throws -> Run? {
            data.runs.last { $0.repo == repo && $0.prNumber == prNumber && $0.workspaceRef != nil }
        }
        func countLaunched(since: Date) throws -> Int {
            data.runs.filter { $0.state == .launched && ($0.launchedAt ?? .distantPast) >= since }.count
        }

        func attach(_ event: Event, toRun runId: UUID) throws {
            data.runEvents.removeAll { $0.event.dedupeKey == event.dedupeKey }
            data.runEvents.append((runId, event))
        }
        func events(forRun runId: UUID) throws -> [Event] { data.runEvents.filter { $0.runId == runId }.map(\.event) }

        func baseline(repoId: UUID, kind: EventKind) throws -> Date? { data.baselines[Self.baselineKey(repoId, kind)] }
        func setBaseline(repoId: UUID, kind: EventKind, at: Date) throws { data.baselines[Self.baselineKey(repoId, kind)] = at }
        func hasAnyBaseline() throws -> Bool { !data.baselines.isEmpty }

        func cursor(sourceType: String) throws -> Date? { data.cursors[sourceType] }
        func setCursor(sourceType: String, _ date: Date) throws { data.cursors[sourceType] = date }
    }
}

public final class InMemoryConfigStore: ConfigStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Config?

    public init(_ config: Config? = nil) { stored = config }

    public func load() throws -> Config { lock.withLock { stored ?? Config() } }
    public func save(_ config: Config) throws { lock.withLock { stored = config } }
}
