import Foundation
@testable import Core

final class FailingStateStore: StateStore, @unchecked Sendable {
    let base = InMemoryStateStore()
    private let lock = NSLock()
    private var _failWrites = false
    var failWrites: Bool { get { lock.withLock { _failWrites } } set { lock.withLock { _failWrites = newValue } } }

    func read<T>(_ body: (any StateAccess) throws -> T) throws -> T { try base.read(body) }
    func write<T>(_ body: (any StateAccess) throws -> T) throws -> T {
        if failWrites { throw FakeError(description: "disk full") }
        return try base.write(body)
    }
}

final class FakeClock: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

struct FakeError: Error, CustomStringConvertible { var description: String }
struct FakeRetryableError: RetryableLaunchError, CustomStringConvertible { var description: String; var retryToken: String }

final class FakeSource: EventSource, @unchecked Sendable {
    static let typeID = "fake"
    let supportedKinds = EventKind.supported
    private let lock = NSLock()
    private var _events: [Event] = []
    private var _open: [PullRequestRef] = []
    private var _error: Error?
    private var _prStates: [Int: PullRequestState] = [:]
    private var _prError: Error?
    private var _contexts: [SourceContext] = []

    var events: [Event] { get { lock.withLock { _events } } set { lock.withLock { _events = newValue } } }
    var openReviewRequests: [PullRequestRef] { get { lock.withLock { _open } } set { lock.withLock { _open = newValue } } }
    var error: Error? { get { lock.withLock { _error } } set { lock.withLock { _error = newValue } } }
    var pullRequestStates: [Int: PullRequestState] { get { lock.withLock { _prStates } } set { lock.withLock { _prStates = newValue } } }
    var pullRequestError: Error? { get { lock.withLock { _prError } } set { lock.withLock { _prError = newValue } } }
    var pollCount: Int { lock.withLock { _contexts.count } }

    func poll(context: SourceContext) async throws -> PollResult {
        try lock.withLock {
            _contexts.append(context)
            if let _error { throw _error }
            return PollResult(events: _events, cursor: Date(), openReviewRequests: _open)
        }
    }

    func pullRequest(url: URL) async throws -> PullRequestRef {
        let parts = url.pathComponents
        let number = Int(parts[4])!
        let (state, error) = lock.withLock { (_prStates[number] ?? .open, _prError) }
        if let error { throw error }
        var pr = makePR(repo: "\(parts[1])/\(parts[2])", number: number)
        pr.state = state
        return pr
    }

    func diagnose() async -> [DiagnosticItem] { [DiagnosticItem(level: .ok, title: "source")] }
}

final class FakeLauncher: Launcher, @unchecked Sendable {
    static let typeID = "fake"
    let capabilities: LauncherCapabilities
    private let lock = NSLock()
    private var _requests: [LaunchRequest] = []
    private var _failures: [any Error] = []
    private var _opened: [(String, JSONValue)] = []
    private var _hold = false
    private var _waiters: [CheckedContinuation<Void, Never>] = []

    init(capabilities: LauncherCapabilities = [.reuseWorkspace]) { self.capabilities = capabilities }

    var requests: [LaunchRequest] { lock.withLock { _requests } }
    var opened: [(String, JSONValue)] { lock.withLock { _opened } }
    func failNext(_ message: String, retryToken: String? = nil) {
        lock.withLock { _failures.append(retryToken.map { FakeRetryableError(description: message, retryToken: $0) } ?? FakeError(description: message)) }
    }
    func hold() { lock.withLock { _hold = true } }
    func release() {
        let waiters = lock.withLock { _hold = false; defer { _waiters = [] }; return _waiters }
        waiters.forEach { $0.resume() }
    }

    func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        let held = lock.withLock { _requests.append(request); return _hold }
        if held { await withCheckedContinuation { c in lock.withLock { _waiters.append(c) } } }
        if let failure = lock.withLock({ _failures.isEmpty ? nil : _failures.removeFirst() }) { throw failure }
        return LaunchResult(workspaceRef: "ws-\(request.runId)", terminalHandle: "term-\(request.runId)")
    }

    func describe(_ request: LaunchRequest) async -> String { "fake launch \(request.subject.pullRequest!.url) \(request.workspacePolicy)" }
    func diagnose(settings: JSONValue) async -> [DiagnosticItem] { [DiagnosticItem(level: .ok, title: "launcher")] }
    func open(_ workspaceRef: String, settings: JSONValue) async throws { lock.withLock { _opened.append((workspaceRef, settings)) } }
}

let startDate = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 10))!
let apiRepo = Repository(id: UUID(), fullName: "o/api")
let webRepo = Repository(id: UUID(), fullName: "o/web")

func makePR(repo: String = "o/api", number: Int = 1, draft: Bool = false, crossRepository: Bool = false, labels: [String] = []) -> PullRequestRef {
    PullRequestRef(host: "github.com", repo: repo, number: number, url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
                   title: "Title \(number)", headRef: "feature/\(number)", headSHA: "sha", baseRef: "main",
                   isDraft: draft, isCrossRepository: crossRepository, labels: labels, author: "alice")
}

func reviewRequested(_ pr: PullRequestRef, at: Date) -> Event {
    Event(kind: .reviewRequested, repo: pr.repo, subject: .pullRequest(pr), occurredAt: at,
          dedupeKey: "rr:\(pr.host)/\(pr.repo)#\(pr.number):\(at.timeIntervalSince1970)")
}

func reviewSubmitted(_ pr: PullRequestRef, id: Int, at: Date, by login: String = "bob", bot: Bool = false, state: String = "COMMENTED") -> Event {
    Event(kind: .reviewSubmitted, repo: pr.repo, subject: .pullRequest(pr), actor: Actor(login: login, isBot: bot), occurredAt: at,
          dedupeKey: "rs:\(pr.host)/\(pr.repo)#\(pr.number):\(id)", review: ReviewInfo(id: id, state: state))
}

func baseConfig() -> Config {
    var config = Config()
    config.repositories = [apiRepo, webRepo]
    config.launchers = [LauncherConfig(id: "main", type: FakeLauncher.typeID)]
    config.promptTemplates = [
        PromptTemplate(id: "rr", name: "rr", body: "Review {{pr.url}}"),
        PromptTemplate(id: "rs", name: "rs", body: "Reply {{review.author}} {{review.state}} x{{review.count}}"),
    ]
    config.rules = [
        Rule(id: "rr", name: "rr", enabled: true, priority: 0, eventKind: .reviewRequested, settleSeconds: 0,
             launcherId: "main", workspacePolicy: .alwaysNew, promptTemplateId: "rr", executionMode: .auto),
        Rule(id: "rs", name: "rs", enabled: true, priority: 0, eventKind: .reviewSubmitted, conditions: [.actorKind(.human)],
             settleSeconds: 120, launcherId: "main", workspacePolicy: .reuseOrCreate, promptTemplateId: "rs", executionMode: .auto),
    ]
    return config
}

struct Harness {
    let clock = FakeClock(startDate)
    let source = FakeSource()
    let launcher: FakeLauncher
    let store = InMemoryStateStore()
    let configStore: InMemoryConfigStore
    let engine: Engine

    init(launcher: FakeLauncher = FakeLauncher(), _ configure: (inout Config) -> Void = { _ in }) throws {
        var config = baseConfig()
        configure(&config)
        self.launcher = launcher
        configStore = InMemoryConfigStore(config)
        engine = try Engine(configStore: configStore, stateStore: store, sources: ["github.com": source],
                            launchers: [FakeLauncher.typeID: launcher], time: clock)
    }

    func restartedEngine() throws -> Engine {
        try Engine(configStore: configStore, stateStore: store, sources: ["github.com": source],
                   launchers: [FakeLauncher.typeID: launcher], time: clock)
    }

    @discardableResult
    func tick() async -> TickOutcome {
        let outcome = await engine.tick()
        await engine.waitForLaunches()
        return outcome
    }

    func runs() async throws -> [Run] { try await engine.recentRuns(limit: 100) }
}
