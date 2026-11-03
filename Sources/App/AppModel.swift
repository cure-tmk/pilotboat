import AppKit
import Core
import Foundation
import LauncherOrca
import LauncherScript
import Observation
import OSLog
import Persistence
import ProcessKit
import ServiceManagement
import SourceGitHub
import SwiftUI

let appLogger = Logger(subsystem: AppPaths.bundleID, category: "app")

@MainActor @Observable
final class AppModel {
    nonisolated static let host = "github.com"
    private static let onboardingKey = "onboardingCompleted"

    let engine: Engine
    let scheduler: Scheduler
    let orcaLauncher: OrcaLauncher
    let scriptLauncher: ScriptLauncher
    let resolvedSearchPath: [String]
    @ObservationIgnored private let github: GitHubSource
    @ObservationIgnored private let secretStore: any SecretStore
    @ObservationIgnored private let runner: ProcessRunner
    @ObservationIgnored private let settingsSnapshot: SettingsSnapshot

    private(set) var config: Config
    private(set) var status: EngineStatus
    private(set) var recentRuns: [Run] = []
    private(set) var pendingRuns: [Run] = []
    private(set) var diagnostics: [DiagnosticItem] = []
    private(set) var githubLogin: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var onboardingCompleted = UserDefaults.standard.bool(forKey: AppModel.onboardingKey)
    var lastErrorMessage: String?
    let router = MainRouter()
    /// Captured from a scene view; `AppModel` has no SwiftUI environment of its own.
    @ObservationIgnored var openWindowAction: OpenWindowAction?

    init(engine: Engine, scheduler: Scheduler, github: GitHubSource, secretStore: any SecretStore, runner: ProcessRunner,
         orcaLauncher: OrcaLauncher, scriptLauncher: ScriptLauncher, settingsSnapshot: SettingsSnapshot,
         config: Config, status: EngineStatus, searchPath: [String]) {
        self.engine = engine; self.scheduler = scheduler; self.github = github; self.secretStore = secretStore; self.runner = runner
        self.orcaLauncher = orcaLauncher; self.scriptLauncher = scriptLauncher; self.settingsSnapshot = settingsSnapshot
        self.config = config; self.status = status; self.resolvedSearchPath = searchPath
    }

    func start() {
        Task { for await event in engine.events { await handle(event) } }
        Task {
            await reloadRuns()
            guard let token = try? await keychain({ try $0.token(host: Self.host) }) else { return }
            githubLogin = try? await github.verifyToken(token)
        }
    }

    private func handle(_ event: EngineEvent) async {
        switch event {
        case .configChanged(let new):
            apply(new)
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
        config = new
        settingsSnapshot.update(new.general)
    }

    private func reloadRuns() async {
        await perform {
            recentRuns = try await engine.recentRuns(limit: 50)
            pendingRuns = try await engine.pendingApprovalRuns()
        }
    }

    // MARK: Config and monitoring

    func updateConfig(_ new: Config) async {
        await updateConfig { $0 = new }
    }

    func updateConfig(_ transform: @Sendable (inout Config) -> Void) async {
        await perform {
            try await engine.updateConfig(transform)
            apply(await engine.config)
        }
    }

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
        let context = SourceContext(repositories: config.repositories.filter { $0.host == Self.host && $0.monitoring },
                                    requestedKinds: [.reviewRequested], cursor: nil)
        await perform { status.openReviewRequests = try await github.poll(context: context).openReviewRequests }
    }

    // MARK: Runs

    func approve(runId: UUID) async { await perform { try await engine.approve(runId: runId) } }
    func skip(runId: UUID) async { await perform { try await engine.skip(runId: runId) } }
    func retry(runId: UUID) async { await perform { try await engine.retry(runId: runId) } }
    func openWorkspace(runId: UUID) async { await perform { try await engine.openWorkspace(runId: runId) } }

    func openPR(run: Run) {
        guard let url = run.snapshot?.subject.pullRequest?.url ?? URL(string: "https://\(Self.host)/\(run.repo)/pull/\(run.prNumber)") else { return }
        NSWorkspace.shared.open(url)
    }

    func eventsForRun(id: UUID) async throws -> [Event] { try await readable { try await engine.eventsForRun(id: id) } }

    func dryRun(ruleId: String, prURL: URL) async throws -> DryRunReport {
        try await readable { try await engine.dryRun(ruleId: ruleId, prURL: prURL) }
    }

    func trialRun(ruleId: String, prURL: URL) async throws -> Run {
        try await readable { try await engine.trialRun(ruleId: ruleId, prURL: prURL) }
    }

    func renderPreview(templateId: String, prURL: URL, kind: EventKind = .reviewRequested) async throws -> String {
        try await readable { try await engine.renderPreview(templateId: templateId, prURL: prURL, kind: kind) }
    }

    func overview(repo: Repository, kind: EventKind) -> OverviewCell {
        RuleMatcher.overview(repo: repo, kind: kind, config: config)
    }

    // MARK: Onboarding and login item

    func completeOnboarding(includeExistingReviewRequests: Bool) async {
        await perform {
            try await engine.completeFirstLaunch(includeExistingReviewRequests: includeExistingReviewRequests)
            UserDefaults.standard.set(true, forKey: Self.onboardingKey)
            onboardingCompleted = true
        }
        guard onboardingCompleted else { return }
        openMain(section: .activity)
        await scheduler.start()
        await triggerTick()
    }

    // MARK: Navigation

    func openMain(section: MainSection? = nil, runId: UUID? = nil, automationId: String? = nil, repositoryId: UUID? = nil) {
        router.show(section: section, runId: runId, automationId: automationId, repositoryId: repositoryId)
        NSApp.activate()
        openWindowAction?(id: WindowID.main)
    }

    func setLaunchAtLogin(_ on: Bool) async {
        do {
            if on { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
        } catch {
            lastErrorMessage = Bundle.main.bundlePath.contains("/AppTranslocation/")
                ? String(localized: "Move Pilotboat to the Applications folder and open it from there to launch it at login", bundle: .resources)
                : Self.describe(error)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: GitHub auth

    @discardableResult
    func signIn(token: String) async throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await readable {
            let login = try await github.verifyToken(token)
            try await keychain { try $0.setToken(token, host: Self.host) }
            githubLogin = login
            await triggerTick()
            return login
        }
    }

    @discardableResult
    func signInWithGhCLI() async throws -> String {
        let result = try await readable { try await runner.run(Command("gh", ["auth", "token", "--hostname", Self.host], timeout: 10)) }
        guard result.succeeded, !result.stdoutText.isEmpty else {
            throw AppError(String(localized: "Could not get a token from gh: \(TokenMasker.mask(result.errorTail))", bundle: .resources))
        }
        return try await signIn(token: result.stdoutText)
    }

    func signOut() async {
        await perform { try await keychain { try $0.removeToken(host: Self.host) } }
        githubLogin = nil
    }

    // Keychain calls can block on a user prompt; keep them off the main thread so the UI stays responsive.
    private func keychain<T: Sendable>(_ body: @escaping @Sendable (any SecretStore) throws -> T) async throws -> T {
        let store = secretStore
        return try await Task.detached { try body(store) }.value
    }

    // MARK: Orca

    private func orcaSettings(launcherId: LauncherID) -> OrcaSettings? {
        guard let settings = config.launcher(id: launcherId)?.settings,
              let data = try? JSONEncoder().encode(settings) else { return nil }
        return try? JSONDecoder().decode(OrcaSettings.self, from: data)
    }

    func orcaRepos(launcherId: LauncherID = Bootstrap.defaultOrcaLauncherId) async throws -> [OrcaRepo] {
        let launcher = OrcaLauncher(runner: runner, settingsOverride: orcaSettings(launcherId: launcherId))
        return try await readable { try await launcher.listRepos() }
    }

    /// Fills missing `launcherBindings[launcherId]` from Orca repos whose canonical key is `host/fullName`. Returns how many were bound.
    @discardableResult
    func bindRepositoriesToOrca(launcherId: LauncherID = Bootstrap.defaultOrcaLauncherId) async -> Int {
        let repos: [OrcaRepo]
        do { repos = try await orcaRepos(launcherId: launcherId) } catch {
            lastErrorMessage = error.localizedDescription
            return 0
        }
        let byKey = Dictionary(repos.compactMap { r in r.canonicalKey.map { ($0.lowercased(), r.id) } }, uniquingKeysWith: { a, _ in a })
        let bindings = Dictionary(uniqueKeysWithValues: config.repositories.compactMap { repo in
            repo.launcherBindings[launcherId] == nil ? byKey["\(repo.host)/\(repo.fullName)".lowercased()].map { (repo.id, $0) } : nil
        })
        guard !bindings.isEmpty else { return 0 }
        await updateConfig { config in
            for i in config.repositories.indices {
                if let id = bindings[config.repositories[i].id] { config.repositories[i].launcherBindings[launcherId] = id }
            }
        }
        return bindings.count
    }

    // MARK: Diagnostics, export and import

    func refreshDiagnostics() async {
        var items = await engine.diagnostics()
        for tool in ["git", "orca", "claude"] {
            guard let path = PathResolver.find(tool, in: resolvedSearchPath) else {
                items.append(DiagnosticItem(level: .warning, title: tool, detail: String(localized: "Not found on PATH", bundle: .resources)))
                continue
            }
            let result = try? await runner.run(Command(path, ["--version"], timeout: 5))
            let version = result.flatMap { $0.succeeded ? $0.stdoutText.split(separator: "\n").first.map(String.init) : nil }
            items.append(DiagnosticItem(level: version == nil ? .warning : .ok, title: tool,
                                        detail: "\(path) — \(version ?? String(localized: "version unknown", bundle: .resources))"))
        }
        items.append(DiagnosticItem(level: .ok, title: String(localized: "PATH", bundle: .resources), detail: resolvedSearchPath.joined(separator: "\n")))
        diagnostics = items
    }

    func exportConfig(to url: URL) async {
        await perform {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ConfigExport.export(config)).write(to: url, options: .atomic)
        }
    }

    /// Applies the import right away; the result lists conflicts resolved with `policy` and launchers needing an executable.
    func importConfig(from url: URL, policy: ImportConflictPolicy) async throws -> ImportResult {
        let result = try await readable {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return ConfigExport.importing(try decoder.decode(ExportedConfig.self, from: Data(contentsOf: url)), into: config, conflictPolicy: policy)
        }
        let imported = result.config
        try await readable {
            try await engine.updateConfig { @Sendable in $0 = imported }
            apply(await engine.config)
        }
        return result
    }

    func exportLogs(to url: URL) async {
        await perform { try await Task.detached { try Self.writeLogs(to: url) }.value }
    }

    private nonisolated static func writeLogs(to url: URL) throws {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: Date().addingTimeInterval(-86_400)),
                                           matching: NSPredicate(format: "subsystem == %@", AppPaths.bundleID))
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
            "\($0.date.formatted(.iso8601)) [\($0.category)] \(TokenMasker.mask($0.composedMessage))"
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Errors

    private func perform(_ body: () async throws -> Void) async {
        do { try await body() } catch { lastErrorMessage = Self.describe(error) }
    }

    private func readable<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw AppError(Self.describe(error)) }
    }

    static func describe(_ error: any Error) -> String {
        let message: String = switch error {
        case let e as EngineError:
            switch e {
            case .ruleNotFound(let id): String(localized: "Rule not found: \(id)", bundle: .resources)
            case .templateNotFound(let id): String(localized: "Prompt template not found: \(id)", bundle: .resources)
            case .launcherNotFound(let id): String(localized: "Launcher not found: \(id)", bundle: .resources)
            case .noSourceForHost(let host): String(localized: "Unsupported host: \(host)", bundle: .resources)
            case .runNotFound: String(localized: "Run not found", bundle: .resources)
            case .invalidTransition(let state): String(localized: "Not possible while the run is \(state.rawValue)", bundle: .resources)
            case .unsupportedSubject: String(localized: "Only pull requests are supported", bundle: .resources)
            }
        case CommandError.executableNotFound(let name): String(localized: "\(name) was not found on PATH", bundle: .resources)
        case CommandError.launchFailed(let reason): String(localized: "Could not start the command: \(reason)", bundle: .resources)
        case is LocalizedError: error.localizedDescription
        default: String(describing: error)
        }
        return TokenMasker.mask(message)
    }
}
