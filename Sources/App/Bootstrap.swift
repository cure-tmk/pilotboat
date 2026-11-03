import AppKit
import Core
import Foundation
import LauncherOrca
import LauncherScript
import os
import Persistence
import ProcessKit
import SourceGitHub

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class SettingsSnapshot: Sendable {
    private let lock: OSAllocatedUnfairLock<GeneralSettings>
    init(_ general: GeneralSettings) { lock = OSAllocatedUnfairLock(initialState: general) }
    func update(_ general: GeneralSettings) { lock.withLock { $0 = general } }
    var includeTeamReviewRequests: Bool { lock.withLock { $0.includeTeamReviewRequests } }
    var excludedActors: [String] { lock.withLock { $0.excludedActors } }
}

enum Bootstrap {
    static let defaultOrcaLauncherId: LauncherID = "orca"

    @MainActor
    static func make() async throws -> AppModel {
        try FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        let configStore = FileConfigStore()
        var startupMessage: String?
        var config: Config
        do {
            config = try configStore.load()
        } catch ConfigStoreError.corrupt(let path, true) {
            config = try configStore.restoreFromBackup()
            startupMessage = String(localized: "The settings file was damaged and has been restored from its backup: \(path)", bundle: .resources)
        } catch ConfigStoreError.corrupt(let path, false) {
            throw AppError(String(localized: "The settings file is damaged and no backup is available. Fix or remove \(path) and relaunch", bundle: .resources))
        }

        let original = config
        if config.presetState.isEmpty {
            Presets.install(into: &config, launcherId: defaultOrcaLauncherId)
            if config.launcher(id: defaultOrcaLauncherId) == nil {
                let settings = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(OrcaSettings(agent: "claude")))
                config.launchers.append(LauncherConfig(id: defaultOrcaLauncherId, type: OrcaLauncher.typeID, settings: settings))
            }
        }
        Presets.upgrade(&config)
        if config != original { try configStore.save(config) }

        let stateStore = try GRDBStateStore(url: AppPaths.stateURL)
        let secretStore = KeychainSecretStore()
        let searchPath = await PathResolver.resolve()
        let runner = ProcessRunner(searchPath: searchPath)
        let snapshot = SettingsSnapshot(config.general)
        let time = SystemTimeSource()
        let github = GitHubSource(host: AppModel.host, secretStore: secretStore, time: time,
                                  includeTeamReviewRequests: { snapshot.includeTeamReviewRequests },
                                  excludedActors: { snapshot.excludedActors })
        let orca = OrcaLauncher(runner: runner)
        let script = ScriptLauncher(runner: runner)
        let engine = try Engine(configStore: configStore, stateStore: stateStore, sources: [AppModel.host: github],
                                launchers: [OrcaLauncher.typeID: orca, ScriptLauncher.typeID: script], time: time)
        let scheduler = Scheduler(engine: engine, time: time)

        let model = AppModel(engine: engine, scheduler: scheduler, github: github, secretStore: secretStore, runner: runner,
                             orcaLauncher: orca, scriptLauncher: script, settingsSnapshot: snapshot,
                             config: await engine.config, status: await engine.status, searchPath: searchPath)
        model.lastErrorMessage = startupMessage
        model.start()
        // Before onboarding, a tick would set first-launch baselines without the user's carry-over choice.
        if model.onboardingCompleted { await scheduler.start() }

        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            Task { await scheduler.triggerNow() }
        }
        appLogger.info("Started; PATH=\(searchPath.joined(separator: ":"), privacy: .public)")
        return model
    }
}
