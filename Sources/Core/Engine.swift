import Foundation

public actor Engine {
    static let processedRetention: TimeInterval = 90 * 86_400
    static let maxSettle: TimeInterval = 600
    static let approvalTimeout: TimeInterval = 86_400
    static let unfinishedStates: [RunState] = [.settling, .pendingApproval, .queued, .held]

    public private(set) var config: Config
    public private(set) var status: EngineStatus
    public nonisolated let events: AsyncStream<EngineEvent>

    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let configStore: any ConfigStore
    private let stateStore: any StateStore
    private let sources: [String: any EventSource]
    private let launchers: [String: any Launcher]
    private let time: any TimeSource
    private var isTicking = false
    private var launchTasks: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - sources: keyed by host (`github.com`).
    ///   - launchers: keyed by launcher `typeID`.
    /// First-launch baselines are not set here so onboarding can call `completeFirstLaunch` with the user's
    /// choice; if it has not by the first `tick`, the tick sets them without carrying over review requests.
    public init(configStore: any ConfigStore, stateStore: any StateStore, sources: [String: any EventSource],
                launchers: [String: any Launcher], time: any TimeSource = SystemTimeSource()) throws {
        let config = try configStore.load()
        self.config = config
        self.status = EngineStatus(monitoring: Self.monitoring(config.general))
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(100))
        self.configStore = configStore
        self.stateStore = stateStore
        self.sources = sources
        self.launchers = launchers
        self.time = time
        let now = time.now
        try stateStore.write { s in
            for var run in try s.runs(state: .launching) {
                run.state = .failed
                run.error = "Pilotboat quit while launching"
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
        var errors: [String] = []

        do {
            if !config.general.monitoring, let until = config.general.monitoringOffUntil, until <= time.now {
                try apply { $0.general.monitoring = true; $0.general.monitoringOffUntil = nil }
            }
            if try !stateStore.read({ try $0.hasAnyBaseline() }) {
                try completeFirstLaunch(includeExistingReviewRequests: false)
            }
        } catch { errors.append("\(error)") }

        var openReviewRequests: [String: [PullRequestRef]] = [:]
        if config.general.monitoring {
            for host in sources.keys.sorted() {
                do {
                    if let result = try await poll(host: host, source: sources[host]!) {
                        openReviewRequests[host] = result.openReviewRequests
                        status.rateLimitRemaining = result.rateLimitRemaining
                    }
                } catch { errors.append("\(host): \(error)") }
            }
        }

        let closed = await closedPendingRuns()
        do { try advanceRuns(closedPendingRuns: closed) } catch { errors.append("\(error)") }
        dispatch()

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
        let kinds = Set(config.rules.filter(\.enabled).map(\.eventKind)).intersection(source.supportedKinds)
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
        var closed: Set<UUID> = []
        for run in pending {
            guard let pr = run.snapshot?.subject.pullRequest, let source = sources[pr.host],
                  let current = try? await source.pullRequest(url: pr.url), current.state != .open else { continue }
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
                notices.append(try Self.settle(run, config: config, now: now, viaApproval: true, s))
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

    /// Renders the snapshot of a run whose settle window ended and moves it on.
    private static func settle(_ run: Run, config: Config, now: Date, viaApproval: Bool, _ s: any StateAccess) throws -> EngineEvent {
        var run = run
        run.updatedAt = now
        let events = try s.events(forRun: run.id)
        let notice: EngineEvent
        if let rule = config.rule(id: run.ruleId), rule.enabled || !viaApproval {
            if let latest = events.max(by: { $0.occurredAt < $1.occurredAt }), let template = config.promptTemplate(id: rule.promptTemplateId) {
                run.snapshot = RunSnapshot(launcherId: rule.launcherId, workspacePolicy: rule.workspacePolicy,
                                           renderedPrompt: PromptRenderer.render(template: template.body, events: events),
                                           subject: latest.subject)
                if latest.subject.pullRequest?.isCrossRepository == true {
                    run.state = .skipped
                    run.skipReason = .crossRepository
                    notice = .runsChanged
                } else if viaApproval && rule.executionMode == .confirm {
                    run.state = .pendingApproval
                    notice = .runNeedsApproval(run)
                } else {
                    run.state = .queued
                    notice = .runsChanged
                }
            } else {
                run.state = .failed
                run.error = "Prompt template \(rule.promptTemplateId) not found"
                notice = .runFailed(run)
            }
        } else {
            run.state = .skipped
            run.skipReason = .ruleRemoved
            notice = .runsChanged
        }
        try s.updateRun(run)
        return notice
    }

    // MARK: Queue and launch

    private func dispatch() {
        let now = time.now
        let general = config.general
        let today = Calendar.current.startOfDay(for: now)
        let result = Result {
            try stateStore.write { s in
                var launching = try s.runs(state: .launching)
                let launchedToday = try s.countLaunched(since: today)
                var started: [Run] = []
                var notices: [EngineEvent] = []
                let candidates = try (s.runs(state: .queued) + s.runs(state: .held).filter { $0.updatedAt < today })
                    .sorted { $0.createdAt < $1.createdAt }
                for var run in candidates {
                    guard launching.count < general.maxConcurrentLaunches else { break }
                    guard !launching.contains(where: { $0.repo == run.repo && $0.prNumber == run.prNumber }) else { continue }
                    run.updatedAt = now
                    if launchedToday >= general.dailyLaunchLimit {
                        run.state = .held
                        notices.append(.runHeld(run))
                    } else if launchedToday + launching.count >= general.dailyLaunchLimit {
                        // In-flight launches may still fail; each completion dispatches again.
                        break
                    } else {
                        run.state = .launching
                        launching.append(run)
                        started.append(run)
                        notices.append(.runsChanged)
                    }
                    try s.updateRun(run)
                }
                return (started, notices)
            }
        }
        switch result {
        case .failure(let error):
            status.lastError = "\(error)"
        case .success(let (started, notices)):
            emit(notices)
            for run in started { launchTasks[run.id] = Task { await self.launch(run) } }
        }
    }

    private func launch(_ run: Run) async {
        var run = run
        do {
            guard let snapshot = run.snapshot else { throw EngineError.invalidTransition(from: run.state) }
            let (launcher, request) = try launchPlan(runId: run.id, snapshot: snapshot, retryToken: run.retryToken)
            let result = try await launcher.launch(request)
            run.state = .launched
            run.workspaceRef = result.workspaceRef
            run.terminalHandle = result.terminalHandle
            run.retryToken = result.retryToken
            run.launchedAt = time.now
            run.error = nil
        } catch {
            run.state = .failed
            run.error = "\(error)"
            if let error = error as? RetryableLaunchError { run.retryToken = error.retryToken }
        }
        run.updatedAt = time.now
        do { try stateStore.write { try $0.updateRun(run) } } catch { status.lastError = "\(error)" }
        emit([run.state == .launched ? .runLaunched(run) : .runFailed(run)])
        launchTasks[run.id] = nil
        dispatch()
    }

    private func launchPlan(runId: UUID, snapshot: RunSnapshot, retryToken: String? = nil) throws -> (any Launcher, LaunchRequest) {
        guard let launcherConfig = config.launcher(id: snapshot.launcherId), let launcher = launchers[launcherConfig.type] else {
            throw EngineError.launcherNotFound(snapshot.launcherId)
        }
        guard let pr = snapshot.subject.pullRequest else { throw EngineError.unsupportedSubject }
        let previous = try stateStore.read { try $0.latestRunWithWorkspace(repo: pr.repo, prNumber: pr.number) }
        let policy: WorkspacePolicy = launcher.capabilities.contains(.reuseWorkspace) ? snapshot.workspacePolicy : .alwaysNew
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
        var newlyCovered = Self.coveredKinds(new).subtracting(Self.coveredKinds(old))
        if !old.general.includeTeamReviewRequests && new.general.includeTeamReviewRequests { newlyCovered.insert(.reviewRequested) }
        let anySkipped = try stateStore.write { s in
            let resumed = !old.general.monitoring && new.general.monitoring
            for repo in new.repositories {
                var kinds = newlyCovered
                if resumed { kinds = EventKind.supported }
                if let previous = old.repository(id: repo.id), previous.monitoring || !repo.monitoring {
                    kinds.formUnion(previous.mutedEventKinds.subtracting(repo.mutedEventKinds))
                } else {
                    kinds = EventKind.supported
                }
                for kind in kinds { try s.setBaseline(repoId: repo.id, kind: kind, at: now) }
                // distantPast, not absent: StateAccess cannot delete, and an earlier baseline would otherwise still block.
                if resumed && includeExistingReviewRequests { try s.setBaseline(repoId: repo.id, kind: .reviewRequested, at: .distantPast) }
            }
            var anySkipped = false
            for state in Self.unfinishedStates {
                for var run in try s.runs(state: state) where Self.outOfScope(run, old) == nil {
                    guard let reason = Self.outOfScope(run, new) else { continue }
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
        status.monitoring = Self.monitoring(new.general)
        emit([.configChanged(new), .statusChanged(status)] + (anySkipped ? [.runsChanged] : []))
    }

    private static func coveredKinds(_ config: Config) -> Set<EventKind> {
        Set(config.rules.filter(\.enabled).map(\.eventKind))
    }

    // ponytail: runs are matched to repositories by fullName only; add the host to Run if several hosts share names.
    private static func outOfScope(_ run: Run, _ config: Config) -> SkipReason? {
        guard let rule = config.rule(id: run.ruleId), rule.enabled else { return .ruleRemoved }
        guard config.general.monitoring,
              let repo = config.repositories.first(where: { $0.fullName == run.repo }),
              repo.monitoring, !repo.mutedEventKinds.contains(rule.eventKind) else { return .monitoringOff }
        return nil
    }

    private static func monitoring(_ general: GeneralSettings) -> EngineStatus.Monitoring {
        if general.monitoring { return .on }
        return general.monitoringOffUntil.map { .offUntil($0) } ?? .off
    }

    // MARK: Run actions

    public func approve(runId: UUID) throws {
        try transition(runId, from: [.pendingApproval]) { $0.state = .queued }
        dispatch()
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
        dispatch()
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
        let (launcher, request) = try launchPlan(runId: UUID(), snapshot: snapshot)
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
            return try Self.settle(run, config: config, now: now, viaApproval: false, s)
        }
        emit([notice])
        dispatch()
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
