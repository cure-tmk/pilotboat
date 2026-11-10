import Core
import Foundation
import LauncherOrca
import Observation
import ProcessKit

/// Orca repository lookups, cached for the session, and linking Pilotboat repositories to them by canonical key.
@MainActor @Observable
final class OrcaLinker {
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let runner: any CommandRunner
    @ObservationIgnored private var cache: [LauncherID: [OrcaRepo]] = [:]

    init(runner: any CommandRunner) { self.runner = runner }

    func repos(launcherId: LauncherID) async throws -> [OrcaRepo] {
        if let cached = cache[launcherId] { return cached }
        let launcher = OrcaLauncher(runner: runner, settingsOverride: model?.orcaSettings(launcherId: launcherId))
        do {
            let repos = try await launcher.listRepos()
            cache[launcherId] = repos
            return repos
        } catch {
            throw AppError(AppModel.describe(error))
        }
    }

    func refresh() { cache = [:] }

    /// Fills missing bindings for `launcherId` from Orca repos whose canonical key is `host/fullName`. Returns how many were bound.
    @discardableResult
    func bind(launcherId: LauncherID, reportErrors: Bool = true) async -> Int {
        guard let model else { return 0 }
        let repos: [OrcaRepo]
        do { repos = try await self.repos(launcherId: launcherId) } catch {
            if reportErrors { model.report(error) }
            return 0
        }
        let bindings = Self.bindings(for: model.config.repositories, launcherId: launcherId, orcaRepos: repos)
        guard !bindings.isEmpty else { return 0 }
        model.edit { config in
            for i in config.repositories.indices {
                if let id = bindings[config.repositories[i].id] { config.repositories[i].launcherBindings[launcherId] = id }
            }
        }
        return bindings.count
    }

    /// Called by the model after repositories were added; links them to every Orca launcher without surfacing errors.
    func repositoriesAdded() async {
        for launcher in model?.config.launchers(ofType: OrcaLauncher.typeID) ?? [] {
            await bind(launcherId: launcher.id, reportErrors: false)
        }
    }

    nonisolated static func bindings(for repositories: [Repository], launcherId: LauncherID, orcaRepos: [OrcaRepo]) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for repo in repositories where repo.launcherBindings[launcherId] == nil {
            if let match = orcaRepos.first(where: { $0.fullName(host: repo.host)?.lowercased() == repo.fullName.lowercased() }) {
                result[repo.id] = match.id
            }
        }
        return result
    }
}
