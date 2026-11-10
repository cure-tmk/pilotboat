import Foundation

public actor Engine {
    static let processedRetention: TimeInterval = 90 * 86_400
    static let maxSettle: TimeInterval = 600
    static let approvalTimeout: TimeInterval = 86_400
    static let unfinishedStates: [RunState] = [.settling, .pendingApproval, .queued, .held]
    static let eventBufferSize = 100
    /// Each check is one GitHub request per pending run, so it is spread out to spare the rate limit.
    static let pullRequestCheckEveryTicks = 5

    public private(set) var config: Config
    public private(set) var status: EngineStatus
    public nonisolated let events: AsyncStream<EngineEvent>

    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let configStore: any ConfigStore
    private let stateStore: any StateStore
    private let sources: [String: any EventSource]
    private let launchers: [String: any Launcher]
    private let time: any TimeSource
    private let describeError: @Sendable (any Error) -> String
    private var isTicking = false
    private var launchTasks: [UUID: Task<Void, Never>] = [:]
    private var tickCount = 0
    private var lastPullRequestCheck: [UUID: Int] = [:]
    private var lastPurgeDay: Date

    /// - Parameters:
    ///   - sources: keyed by host (`github.com`).
    ///   - launchers: keyed by launcher `typeID`.
    ///   - describeError: turns errors into the text stored on runs and shown as `status.lastError`.
    /// First-launch baselines are not set here so onboarding can call `completeFirstLaunch` with the user's
    /// choice; if it has not by the first `tick`, the tick sets them without carrying over review requests.
    public init(configStore: any ConfigStore, stateStore: any StateStore, sources: [String: any EventSource],
                launchers: [String: any Launcher], time: any TimeSource = SystemTimeSource(),
                describeError: @escaping @Sendable (any Error) -> String = { ($0 as? LocalizedError)?.errorDescription ?? String(describing: $0) }) throws {
        let config = try configStore.load()
        self.config = config
        self.status = EngineStatus(monitoring: RunPolicy.monitoring(config.general))
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(Self.eventBufferSize))
        self.configStore = configStore
        self.stateStore = stateStore
        self.sources = sources
        self.launchers = launchers
        self.time = time
        self.describeError = describeError
        let now = time.now
        lastPurgeDay = Calendar.current.startOfDay(for: now)
        let interrupted = describeError(EngineError.interruptedLaunch)
        try stateStore.write { s in
            for var run in try s.runs(state: .launching) {
                run.state = .failed
                run.error = interrupted
                run.updatedAt = now
                try s.updateRun(run)
            }
            try s.purgeProcessedEvents(before: now.addingTimeInterval(-Self.processedRetention))
        }
    }

    // MARK: Tick

    public func tick() async -> TickOutcome {
        guard !isTicking else { return .busy }
        isTicking = true
        defer { isTicking = false }
        tickCount += 1
        var errors: [String] = []

        let now = time.now
        if Calendar.current.startOfDay(for: now) > lastPurgeDay {
            do {
                try stateStore.write { try $0.purgeProcessedEvents(before: now.addingTimeInterval(-Self.processedRetention)) }
                lastPurgeDay = Calendar.current.startOfDay(for: now)
            } catch { errors.append(describeError(error)) }
        }
        do {
            if !config.general.monitoring, let until = config.general.monitoringOffUntil, until <= now {
                try apply { $0.general.monitoring = true; $0.general.monitoringOffUntil = nil }
            }
            if try !stateStore.read({ try $0.hasAnyBaseline() }) {
                try completeFirstLaunch(includeExistingReviewRequests: false)
            }
        } catch { errors.append(describeError(error)) }

        var openReviewRequests: [String: [PullRequestRef]] = [:]
        if config.general.monitoring {
            for host in sources.keys.sorted() {
                do {
                    if let result = try await poll(host: host, source: sources[host]!) {
                        openReviewRequests[host] = result.openReviewRequests
                        status.rateLimitRemaining = result.rateLimitRemaining
                    }
                } catch { errors.append("\(host): \(describeError(error))") }
            }
        }

        let closed = await closedPendingRuns()
        do { try advanceRuns(closedPendingRuns: closed) } catch { errors.append(describeError(error)) }
        do { try dispatch() } catch { errors.append(describeError(error)) }

        status.lastTickAt = time.now
        status.lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        status.consecutiveFailures = errors.isEmpty ? 0 : status.consecutiveFailures + 1
        if config.general.monitoring { status.openReviewRequests = openReviewRequests.keys.sorted().flatMap { openReviewRequests[$0]! } }
        continuation.yield(.statusChanged(status))

        if !errors.isEmpty { return .failed(consecutiveFailures: status.consecutiveFailures) }
        return config.general.monitoring ? .completed : .monitoringOff(until: config.general.monitoringOffUntil)
    }

    /// `nil` when monitoring was turned off while polling; the result is then dropped and the cursor kept.
    private func poll(host: String, source: any EventSource) async throws -> PollResult? {
        let cursorKey = "\(type(of: source).typeID):\(host)"
        let kinds = RunPolicy.coveredKinds(config).intersection(source.supportedKinds)
        let context = SourceContext(repositories: config.repositories.filter { $0.host == host && $0.monitoring },
                                    requestedKinds: kinds,
                                    cursor: try stateStore.read { try $0.cursor(sourceType: cursorKey) })
        let result = try await source.poll(context: context)
        guard config.general.monitoring else { return nil }
        let config = config
        let now = time.now
        try stateStore.write { s in
            for event in result.events { try Self.ingest(event, config: config, now: now, s) }
            try s.setCursor(sourceType: cursorKey, result.cursor)
        }
        return result
    }

    private static func ingest(_ event: Event, config: Config, now: Date, _ s: any StateAccess) throws {
        guard try !s.hasProcessed(dedupeKey: event.dedupeKey) else { return }
        try s.markProcessed(event, seenAt: now)
        guard let pr = event.subject.pullRequest, let repo = config.repository(host: pr.host, fullName: event.repo) else { return }
        if let baseline = try s.baseline(repoId: repo.id, kind: event.kind), event.occurredAt < baseline { return }
        guard case .matched(let rule) = RuleMatcher.match(event, in: repo, config: config) else { return }
        let settle = TimeInterval(rule.settleSeconds)
        if var run = try s.settlingRun(ruleId: rule.id, repo: event.repo, prNumber: pr.number) {
            run.settleUntil = min(now + settle, run.createdAt + maxSettle)
            run.updatedAt = now
            try s.updateRun(run)
            try s.attach(event, toRun: run.id)
        } else {
            let run = Run(state: .settling, ruleId: rule.id, repo: event.repo, prNumber: pr.number,
                          settleUntil: now + min(settle, maxSettle), createdAt: now, updatedAt: now)
            try s.insertRun(run)
            try s.attach(event, toRun: run.id)
        }
    }

    /// Pending runs whose PR is no longer open; a run whose PR cannot be fetched is left alone.
    private func closedPendingRuns() async -> Set<UUID> {
        guard let pending = try? stateStore.read({ try $0.runs(state: .pendingApproval) }) else { return [] }
        let pendingIds = Set(pending.map(\.id))
        lastPullRequestCheck = lastPullRequestCheck.filter { pendingIds.contains($0.key) }
        var closed: Set<UUID> = []
        for run in pending {
            if let last = lastPullRequestCheck[run.id], tickCount - last < Self.pullRequestCheckEveryTicks { continue }
            guard let pr = run.snapshot?.subject.pullRequest, let source = sources[pr.host] else { continue }
            lastPullRequestCheck[run.id] = tickCount
            guard let current = try? await source.pullRequest(url: pr.url), current.state != .open else { continue }
            closed.insert(run.id)
        }
        return closed
    }

    private func advanceRuns(closedPendingRuns: Set<UUID>) throws {
        let now = time.now
        let config = config
        let notices = try stateStore.write { s in
            var notices: [EngineEvent] = []
            for run in try s.runs(state: .settling) where (run.settleUntil ?? now) <= now {
                let (settled, notice) = RunPolicy.settle(run: run, events: try s.events(forRun: run.id), config: config, now: now,
                                                         viaApproval: true, describeError: describeError)
                try s.updateRun(settled)
                notices.append(notice)
            }
            for var run in try s.runs(state: .pendingApproval) {
                if now.timeIntervalSince(run.updatedAt) >= Self.approvalTimeout {
                    run.skipReason = .approvalTimeout
                } else if closedPendingRuns.contains(run.id) {
                    run.skipReason = .prClosed
                } else { continue }
                run.state = .skipped
                run.updatedAt = now
                try s.updateRun(run)
                notices.append(.runsChanged)
            }
            return notices
        }
        emit(notices)
    }

    // MARK: Queue and launch

    private func dispatch() throws {
        let now = time.now
        let general = config.general
        let today = Calendar.current.startOfDay(for: now)
        let plan = try stateStore.write { s in
            let plan = RunPolicy.planDispatch(candidates: try s.runs(state: .queued) + s.runs(state: .held),
                                              launching: try s.runs(state: .launching),
                                              launchedToday: try s.countLaunched(since: today), general: general, now: now)
            for run in plan.updates { try s.updateRun(run) }
            return plan
        }
        emit(plan.notices)
        for run in plan.started { launchTasks[run.id] = Task { await self.launch(run) } }
    }

    /// For dispatches outside `tick`, which counts failures itself.
    private func dispatchReportingFailure() {
        do { try dispatch() } catch { report(error) }
    }

    private func report(_ error: any Error) {
        status.lastError = describeError(error)
        continuation.yield(.statusChanged(status))
    }

    private func launch(_ run: Run) async {
        var run = run
        do {
            guard let snapshot = run.snapshot else { throw EngineError.invalidTransition(from: run.state) }
            let (launcher, request) = try await launchPlan(runId: run.id, snapshot: snapshot, retryToken: run.retryToken)
            let result = try await launcher.launch(request)
            run.state = .launched
            run.workspaceRef = result.workspaceRef
            run.terminalHandle = result.terminalHandle
            run.retryToken = result.retryToken
            run.launchedAt = time.now
            run.error = nil
        } catch {
            run.state = .failed
            run.error = describeError(error)
            if let error = error as? RetryableLaunchError { run.retryToken = error.retryToken }
        }
        run.updatedAt = time.now
        do { try stateStore.write { try $0.updateRun(run) } } catch { report(error) }
        emit([run.state == .launched ? .runLaunched(run) : .runFailed(run)])
        launchTasks[run.id] = nil
        dispatchReportingFailure()
    }

    private func launchPlan(runId: UUID, snapshot: RunSnapshot, retryToken: String? = nil) async throws -> (any Launcher, LaunchRequest) {
        guard let launcherConfig = config.launcher(id: snapshot.launcherId), let launcher = launchers[launcherConfig.type] else {
            throw EngineError.launcherNotFound(snapshot.launcherId)
        }
        guard let pr = snapshot.subject.pullRequest else { throw EngineError.unsupportedSubject }
        let previous = try stateStore.read { try $0.latestRunWithWorkspace(repo: pr.repo, prNumber: pr.number) }
        let canReuse = await launcher.capabilities(settings: launcherConfig.settings).contains(.reuseWorkspace)
        let policy: WorkspacePolicy = canReuse ? snapshot.workspacePolicy : .alwaysNew
        let binding = config.repository(host: pr.host, fullName: pr.repo)?.launcherBindings[launcherConfig.id]
        return (launcher, LaunchRequest(runId: runId, subject: snapshot.subject,
                                        repository: RepositoryInfo(host: pr.host, fullName: pr.repo, launcherBinding: binding),
                                        workspacePolicy: policy, prompt: snapshot.renderedPrompt,
                                        previousWorkspaceRef: previous?.workspaceRef, previousTerminalHandle: previous?.terminalHandle,
                                        launcherSettings: launcherConfig.settings, retryToken: retryToken))
    }

    /// Waits until no launch is in flight, including launches started as earlier ones free their slot.
    public func waitForLaunches() async {
        while let task = launchTasks.values.first { await task.value }
    }

    // MARK: Config and monitoring

    public func updateConfig(_ transform: (inout Config) throws -> Void) throws {
        try apply(transform)
    }

    public func setMonitoring(_ on: Bool, includeExistingReviewRequests: Bool = false) throws {
        try apply(includeExistingReviewRequests: includeExistingReviewRequests) {
            $0.general.monitoring = on
            $0.general.monitoringOffUntil = nil
        }
    }

    public func pauseMonitoring(until: Date) throws {
        try apply {
            $0.general.monitoring = false
            $0.general.monitoringOffUntil = until
        }
    }

    public func completeFirstLaunch(includeExistingReviewRequests: Bool) throws {
        let now = time.now
        let repos = config.repositories
        try stateStore.write { s in
            for repo in repos {
                for kind in EventKind.supported { try s.setBaseline(repoId: repo.id, kind: kind, at: now) }
                if includeExistingReviewRequests { try s.setBaseline(repoId: repo.id, kind: .reviewRequested, at: .distantPast) }
            }
        }
    }

    /// Sets baselines and skips unfinished runs that the change put out of scope (spec 5.3, F-M6), then persists the new config.
    private func apply(includeExistingReviewRequests: Bool = false, _ transform: (inout Config) throws -> Void) throws {
        let old = config
        var new = old
        try transform(&new)
        guard new != old else { return }
        let now = time.now
        let resumed = !old.general.monitoring && new.general.monitoring
        let anySkipped = try stateStore.write { s in
            for repo in new.repositories {
                for kind in RunPolicy.baselineKinds(old: old, new: new, repo: repo, resumed: resumed) {
                    try s.setBaseline(repoId: repo.id, kind: kind, at: now)
                }
                // distantPast, not absent: StateAccess cannot delete, and an earlier baseline would otherwise still block.
                if resumed && includeExistingReviewRequests { try s.setBaseline(repoId: repo.id, kind: .reviewRequested, at: .distantPast) }
            }
            var anySkipped = false
            for state in Self.unfinishedStates {
                for var run in try s.runs(state: state) where RunPolicy.outOfScope(run, old) == nil {
                    guard let reason = RunPolicy.outOfScope(run, new) else { continue }
                    run.state = .skipped
                    run.skipReason = reason
                    run.updatedAt = now
                    try s.updateRun(run)
                    anySkipped = true
                }
            }
            return anySkipped
        }
        try configStore.save(new)
        config = new
        status.monitoring = RunPolicy.monitoring(new.general)
        emit([.configChanged(new), .statusChanged(status)] + (anySkipped ? [.runsChanged] : []))
    }

    // MARK: Run actions

    public func approve(runId: UUID) throws {
        try transition(runId, from: [.pendingApproval]) { $0.state = .queued }
        dispatchReportingFailure()
    }

    public func skip(runId: UUID) throws {
        try transition(runId, from: Self.unfinishedStates) {
            $0.state = .skipped
            $0.skipReason = .userSkipped
        }
    }

    /// Re-queues a failed run under the same id and `retryToken`, so launchers can recognize the retry.
    public func retry(runId: UUID) throws {
        try transition(runId, from: [.failed]) {
            guard $0.snapshot != nil else { throw EngineError.invalidTransition(from: .failed) }
            $0.state = .queued
            $0.error = nil
        }
        dispatchReportingFailure()
    }

    private func transition(_ runId: UUID, from states: [RunState], _ change: (inout Run) throws -> Void) throws {
        let now = time.now
        try stateStore.write { s in
            guard var run = try s.run(id: runId) else { throw EngineError.runNotFound(runId) }
            guard states.contains(run.state) else { throw EngineError.invalidTransition(from: run.state) }
            try change(&run)
            run.updatedAt = now
            try s.updateRun(run)
        }
        emit([.runsChanged])
    }

    // MARK: Previews and trial runs

    public func dryRun(ruleId: String, prURL: URL) async throws -> DryRunReport {
        let (rule, pr) = try await resolve(ruleId: ruleId, prURL: prURL)
        let event = Event(kind: rule.eventKind, repo: pr.repo, subject: .pullRequest(pr), occurredAt: time.now, dedupeKey: "dryrun")
        let repo = config.repository(host: pr.host, fullName: pr.repo)
        var winner: Rule?
        if let repo, case .matched(let rule) = RuleMatcher.match(event, in: repo, config: config) { winner = rule }
        guard let template = config.promptTemplate(id: rule.promptTemplateId) else { throw EngineError.templateNotFound(rule.promptTemplateId) }
        let snapshot = RunSnapshot(launcherId: rule.launcherId, workspacePolicy: rule.workspacePolicy,
                                   renderedPrompt: PromptRenderer.render(template: template.body, events: [event]), subject: event.subject)
        let (launcher, request) = try await launchPlan(runId: UUID(), snapshot: snapshot)
        return DryRunReport(pullRequest: pr, mismatch: RuleMatcher.mismatch(of: rule, for: event, in: repo, config: config),
                            winningRule: winner, renderedPrompt: snapshot.renderedPrompt,
                            launcherDescription: await launcher.describe(request))
    }

    /// Runs `ruleId` against the PR now, bypassing baseline, dedupe, settle and approval, then queues it.
    public func trialRun(ruleId: String, prURL: URL) async throws -> Run {
        let (rule, pr) = try await resolve(ruleId: ruleId, prURL: prURL)
        let now = time.now
        let event = Event(kind: rule.eventKind, repo: pr.repo, subject: .pullRequest(pr), occurredAt: now,
                          dedupeKey: "trial:\(pr.host)/\(pr.repo)#\(pr.number):\(UUID().uuidString)")
        let run = Run(state: .settling, ruleId: rule.id, repo: pr.repo, prNumber: pr.number, createdAt: now, updatedAt: now)
        let config = config
        let notice = try stateStore.write { s in
            try s.insertRun(run)
            try s.attach(event, toRun: run.id)
            let (settled, notice) = RunPolicy.settle(run: run, events: [event], config: config, now: now,
                                                     viaApproval: false, describeError: describeError)
            try s.updateRun(settled)
            return notice
        }
        emit([notice])
        dispatchReportingFailure()
        return try stateStore.read { try $0.run(id: run.id) } ?? run
    }

    public func renderPreview(templateId: String, prURL: URL, kind: EventKind = .reviewRequested) async throws -> String {
        guard let template = config.promptTemplate(id: templateId) else { throw EngineError.templateNotFound(templateId) }
        let pr = try await pullRequest(url: prURL)
        let event = Event(kind: kind, repo: pr.repo, subject: .pullRequest(pr), occurredAt: time.now, dedupeKey: "preview")
        return PromptRenderer.render(template: template.body, events: [event])
    }

    private func resolve(ruleId: String, prURL: URL) async throws -> (Rule, PullRequestRef) {
        guard let rule = config.rule(id: ruleId) else { throw EngineError.ruleNotFound(ruleId) }
        return (rule, try await pullRequest(url: prURL))
    }

    private func pullRequest(url: URL) async throws -> PullRequestRef {
        let host = url.host() ?? ""
        guard let source = sources[host] else { throw EngineError.noSourceForHost(host) }
        return try await source.pullRequest(url: url)
    }

    // MARK: Queries

    public func recentRuns(limit: Int) throws -> [Run] { try stateStore.read { try $0.recentRuns(limit: limit) } }
    public func run(id: UUID) throws -> Run? { try stateStore.read { try $0.run(id: id) } }
    public func pendingApprovalRuns() throws -> [Run] { try stateStore.read { try $0.runs(state: .pendingApproval) } }
    public func eventsForRun(id: UUID) throws -> [Event] { try stateStore.read { try $0.events(forRun: id) } }

    public func overview(repo: Repository, kind: EventKind) -> OverviewCell {
        RuleMatcher.overview(repo: repo, kind: kind, config: config)
    }

    /// Launcher item titles are prefixed with the launcher id (`main: orca found`).
    public func diagnostics() async -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        for key in sources.keys.sorted() { items += await sources[key]!.diagnose() }
        for launcherConfig in config.launchers {
            for var item in await launchers[launcherConfig.type]?.diagnose(settings: launcherConfig.settings) ?? [] {
                item.title = "\(launcherConfig.id): \(item.title)"
                items.append(item)
            }
        }
        return items
    }

    public func openWorkspace(runId: UUID) async throws {
        guard let run = try stateStore.read({ try $0.run(id: runId) }) else { throw EngineError.runNotFound(runId) }
        guard let workspaceRef = run.workspaceRef, let launcherId = run.snapshot?.launcherId else { throw EngineError.invalidTransition(from: run.state) }
        guard let launcherConfig = config.launcher(id: launcherId), let launcher = launchers[launcherConfig.type] else {
            throw EngineError.launcherNotFound(launcherId)
        }
        try await launcher.open(workspaceRef, settings: launcherConfig.settings)
    }

    private func emit(_ notices: [EngineEvent]) {
        var runsChanged = false
        for notice in notices {
            switch notice {
            case .runsChanged: runsChanged = true
            case .runNeedsApproval, .runLaunched, .runFailed, .runHeld: runsChanged = true; continuation.yield(notice)
            case .configChanged, .statusChanged: continuation.yield(notice)
            }
        }
        if runsChanged { continuation.yield(.runsChanged) }
    }
}
