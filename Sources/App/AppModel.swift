import AppKit
import Core
import Foundation
import LauncherOrca
import Observation
import OSLog
import Persistence
import ProcessKit
import ServiceManagement
import SourceGitHub

let appLogger = Logger(subsystem: AppPaths.bundleID, category: "app")

@MainActor
protocol AppShell: AnyObject {
    func showMain()
    func closePopover()
}

@MainActor @Observable
final class AppModel {
    private static let onboardingKey = "onboardingCompleted"

    let resolvedSearchPath: [String]
    let router = MainRouter()
    let account: GitHubAccount
    let orca: OrcaLinker
    @ObservationIgnored weak var shell: AppShell?
    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private let scheduler: Scheduler
    @ObservationIgnored private let github: GitHubSource
    @ObservationIgnored private let runner: any CommandRunner
    @ObservationIgnored private let launchers: [String: any Launcher]
    @ObservationIgnored private let settingsSnapshot: SettingsSnapshot
    @ObservationIgnored private var writes: Task<Bool, Never>?
    @ObservationIgnored private var pendingWrites = 0

    private(set) var config: Config
    private(set) var status: EngineStatus
    private(set) var recentRuns: [Run] = []
    private(set) var pendingRuns: [Run] = []
    private(set) var health = HealthReport()
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var onboardingCompleted = UserDefaults.standard.bool(forKey: AppModel.onboardingKey)
    var lastErrorMessage: String?

    init(engine: Engine, scheduler: Scheduler, github: GitHubSource, secretStore: any SecretStore, runner: any CommandRunner,
         launchers: [String: any Launcher], settingsSnapshot: SettingsSnapshot, config: Config, status: EngineStatus, searchPath: [String]) {
        self.engine = engine; self.scheduler = scheduler; self.github = github; self.runner = runner
        self.launchers = launchers; self.settingsSnapshot = settingsSnapshot
        self.config = config; self.status = status; self.resolvedSearchPath = searchPath
        account = GitHubAccount(github: github, secretStore: secretStore, runner: runner, searchPath: searchPath)
        orca = OrcaLinker(runner: runner)
        account.model = self
        orca.model = self
    }

    func start() {
        Task { for await event in engine.events { await handle(event) } }
        Task {
            await reloadRuns()
            await account.restore()
        }
    }

    private func handle(_ event: EngineEvent) async {
        switch event {
        case .configChanged(let new):
            // While local edits are in flight the local config is ahead; the last write re-syncs it.
            if pendingWrites == 0 { apply(new) }
        case .statusChanged(let new):
            status = new
            appLogger.info("Tick at \(new.lastTickAt?.formatted(.iso8601) ?? "-", privacy: .public) error=\(new.lastError ?? "none", privacy: .public)")
        case .runsChanged:
            await reloadRuns()
        case .runNeedsApproval(let run):
            if config.general.notificationsEnabled { Notifier.shared.postApproval(run, ruleName: config.rule(id: run.ruleId)?.name ?? run.ruleId) }
        case .runFailed(let run):
            if config.general.notificationsEnabled { Notifier.shared.postFailure(run) }
        case .runLaunched, .runHeld:
            break
        }
    }

    private func apply(_ new: Config) {
        if config != new { config = new }
        settingsSnapshot.update(new.general)
    }

    private func reloadRuns() async {
        await perform {
            let recent = try await engine.recentRuns(limit: 50)
            let pending = try await engine.pendingApprovalRuns()
            if recent != recentRuns { recentRuns = recent }
            if pending != pendingRuns { pendingRuns = pending }
        }
    }

    // MARK: Config

    /// Applies `transform` to `config` right away and writes it to the engine in order with earlier edits.
    /// Returns what the transform returned locally. A failed write re-syncs `config` from the engine and shows the error.
    @discardableResult
    func edit<T>(_ transform: @escaping @Sendable (inout Config) -> T) -> T {
        var after = config
        let result = transform(&after)
        _ = enqueue(after) { _ = transform(&$0) }
        return result
    }

    /// Like `edit`, but waits for the write. Returns whether it succeeded.
    @discardableResult
    func updateConfig(_ transform: @escaping @Sendable (inout Config) -> Void) async -> Bool {
        var after = config
        transform(&after)
        return await enqueue(after, transform).value
    }

    private func enqueue(_ after: Config, _ transform: @escaping @Sendable (inout Config) -> Void) -> Task<Bool, Never> {
        let before = config
        guard after != before else { return Task { true } }
        config = after
        pendingWrites += 1
        let previous = writes
        let write = Task {
            _ = await previous?.value
            return await commit(before: before, after: after, transform)
        }
        writes = write
        return write
    }

    private func commit(before: Config, after: Config, _ transform: @escaping @Sendable (inout Config) -> Void) async -> Bool {
        var succeeded = true
        do {
            // Reusing `after` keeps ids generated by the transform identical to the ones the views already saw.
            try await engine.updateConfig { @Sendable config in
                if config == before { config = after } else { transform(&config) }
            }
        } catch {
            succeeded = false
            report(error)
        }
        pendingWrites -= 1
        // Read first: edits enqueued during the await are ahead of `latest`, and the last write re-syncs, even after a failure here.
        let latest = await engine.config
        if pendingWrites == 0 { apply(latest) }
        guard succeeded else { return false }
        if before.launchers != after.launchers { orca.refresh() }
        if !Set(after.repositories.map(\.id)).subtracting(before.repositories.map(\.id)).isEmpty { await orca.repositoriesAdded() }
        return true
    }

    // MARK: Monitoring

    func setMonitoring(_ on: Bool, includeExistingReviewRequests: Bool = false) async {
        await perform { try await engine.setMonitoring(on, includeExistingReviewRequests: includeExistingReviewRequests) }
        await triggerTick()
    }

    func pauseMonitoring(for duration: Duration) async {
        await pauseMonitoring(until: Date().addingTimeInterval(TimeInterval(duration.components.seconds)))
    }

    func pauseMonitoringUntilTomorrow() async {
        let calendar = Calendar.current
        await pauseMonitoring(until: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!)
    }

    private func pauseMonitoring(until: Date) async {
        await perform { try await engine.pauseMonitoring(until: until) }
        await triggerTick()
    }

    var nextCheckAt: Date? {
        guard status.monitoring == .on, let last = status.lastTickAt else { return nil }
        return last.addingTimeInterval(TimeInterval(config.general.pollIntervalSeconds))
    }

    func triggerTick() async {
        await scheduler.triggerNow()
    }

    /// Reads the review requests waiting now, without recording anything.
    // Not `engine.tick()`: a tick marks the waiting requests as processed, so "Handle them too" at the end of onboarding could no longer pick them up.
    func pollOnce() async {
        let context = SourceContext(repositories: config.repositories.filter { $0.host == Repository.defaultHost && $0.monitoring },
                                    requestedKinds: [.reviewRequested], cursor: nil)
        await perform { status.openReviewRequests = try await github.poll(context: context).openReviewRequests }
    }

    // MARK: Runs

    func approve(runId: UUID) async { await perform { try await engine.approve(runId: runId) } }
    func skip(runId: UUID) async { await perform { try await engine.skip(runId: runId) } }
    func retry(runId: UUID) async { await perform { try await engine.retry(runId: runId) } }
    func openWorkspace(runId: UUID) async { await perform { try await engine.openWorkspace(runId: runId) } }

    func openPR(run: Run) {
        guard let url = run.pullRequest?.url ?? URL(string: "https://\(Repository.defaultHost)/\(run.repo)/pull/\(run.prNumber)") else { return }
        NSWorkspace.shared.open(url)
    }

    func eventsForRun(id: UUID) async throws -> [Event] { try await described { try await engine.eventsForRun(id: id) } }

    func dryRun(ruleId: String, prURL: URL) async throws -> DryRunReport {
        try await described { try await engine.dryRun(ruleId: ruleId, prURL: prURL) }
    }

    func trialRun(ruleId: String, prURL: URL) async throws -> Run {
        try await described { try await engine.trialRun(ruleId: ruleId, prURL: prURL) }
    }

    func overview(repo: Repository, kind: EventKind) -> OverviewCell {
        RuleMatcher.overview(repo: repo, kind: kind, config: config)
    }

    // MARK: Launchers

    func capabilities(of launcher: LauncherConfig) async -> LauncherCapabilities {
        await launchers[launcher.type]?.capabilities(settings: launcher.settings) ?? []
    }

    func diagnose(_ launcher: LauncherConfig) async -> [DiagnosticItem] {
        await launchers[launcher.type]?.diagnose(settings: launcher.settings) ?? []
    }

    func orcaSettings(launcherId: LauncherID) -> OrcaSettings? {
        config.launcher(id: launcherId).flatMap { try? OrcaSettings(json: $0.settings) }
    }

    // MARK: Onboarding and login item

    func completeOnboarding(includeExistingReviewRequests: Bool) async {
        await perform {
            try await engine.completeFirstLaunch(includeExistingReviewRequests: includeExistingReviewRequests)
            UserDefaults.standard.set(true, forKey: Self.onboardingKey)
            onboardingCompleted = true
        }
        guard onboardingCompleted else { return }
        await scheduler.start()
        await triggerTick()
    }

    func setLaunchAtLogin(_ on: Bool) async {
        do {
            if on { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
        } catch {
            report(Bundle.main.bundlePath.contains("/AppTranslocation/")
                ? AppError(String(localized: "Move Pilotboat to the Applications folder and open it from there to launch it at login", bundle: .resources))
                : error)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Diagnostics

    func refreshDiagnostics() async {
        orca.refresh()
        let items = await engine.diagnostics()
        var tools: [ToolCheck] = []
        for name in ["git", "orca", "claude"] { tools.append(await probe(name)) }
        health = HealthReport.make(from: items, tools: tools, searchPath: resolvedSearchPath)
    }

    private func probe(_ name: String) async -> ToolCheck {
        guard let path = PathResolver.find(name, in: resolvedSearchPath) else { return ToolCheck(name: name) }
        let result = try? await runner.run(Command(path, ["--version"], timeout: 5))
        let version = result.flatMap { $0.succeeded ? $0.stdoutText.split(separator: "\n").first.map(String.init) : nil }
        return ToolCheck(name: name, path: path, version: version)
    }

    // MARK: Errors

    func report(_ error: any Error) {
        let message = Self.describe(error)
        appLogger.error("\(message, privacy: .public)")
        lastErrorMessage = message
    }

    func perform(_ body: () async throws -> Void) async {
        do { try await body() } catch { report(error) }
    }

    func described<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw AppError(Self.describe(error)) }
    }
}
