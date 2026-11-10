import Core
import Foundation
import LauncherOrca
import LauncherScript
import Persistence
import ProcessKit
import SourceGitHub

/// An error whose message is already user-facing; `AppModel.describe` passes it through.
struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension AppModel {
    nonisolated static func describe(_ error: any Error) -> String {
        let message: String = switch error {
        case let e as AppError: e.message
        case let e as EngineError: describe(e)
        case let e as CommandError: describe(e)
        case let e as GitHubError: describe(e)
        case let e as OrcaLauncherError: describe(e)
        case let e as OrcaRetryableError: e.message
        case let e as ScriptLauncherError: describe(e)
        case let e as ConfigStoreError: describe(e)
        case ConfigEditError.launcherInUse(let names):
            String(localized: "Used by: \(names.joined(separator: ", ")). Change those automations first", bundle: .resources)
        case is LocalizedError: error.localizedDescription
        default: String(describing: error)
        }
        return TokenMasker.mask(message)
    }

    private nonisolated static func describe(_ error: EngineError) -> String {
        switch error {
        case .ruleNotFound(let id): String(localized: "Rule not found: \(id)", bundle: .resources)
        case .templateNotFound(let id): String(localized: "Prompt template not found: \(id)", bundle: .resources)
        case .launcherNotFound(let id): String(localized: "Launcher not found: \(id)", bundle: .resources)
        case .noSourceForHost(let host): String(localized: "Unsupported host: \(host)", bundle: .resources)
        case .runNotFound: String(localized: "Run not found", bundle: .resources)
        case .invalidTransition(let state): String(localized: "Not possible while the run is \(state.rawValue)", bundle: .resources)
        case .unsupportedSubject: String(localized: "Only pull requests are supported", bundle: .resources)
        case .interruptedLaunch: String(localized: "Pilotboat quit while launching", bundle: .resources)
        }
    }

    private nonisolated static func describe(_ error: CommandError) -> String {
        switch error {
        case .executableNotFound(let name): String(localized: "\(name) was not found on PATH", bundle: .resources)
        case .launchFailed(let reason): String(localized: "Could not start the command: \(reason)", bundle: .resources)
        }
    }

    private nonisolated static func describe(_ error: GitHubError) -> String {
        switch error {
        case .noToken: String(localized: "Sign in to GitHub first", bundle: .resources)
        case .unauthorized: String(localized: "The GitHub token is invalid or expired", bundle: .resources)
        case .ssoRequired(let orgs) where orgs.isEmpty: String(localized: "Authorize the token for SAML single sign-on", bundle: .resources)
        case .ssoRequired(let orgs):
            String(localized: "Authorize the token for SAML single sign-on: \(orgs.joined(separator: ", "))", bundle: .resources)
        case .rateLimited(let until):
            String(localized: "GitHub rate limit reached until \(until.formatted(date: .omitted, time: .shortened))", bundle: .resources)
        case .http(let status, _): String(localized: "GitHub returned HTTP \(status)", bundle: .resources)
        case .graphQL(let messages): String(localized: "GitHub returned an error: \(messages.joined(separator: "; "))", bundle: .resources)
        case .network(let underlying): String(localized: "Could not reach GitHub: \(underlying.localizedDescription)", bundle: .resources)
        case .invalidURL: String(localized: "Not a pull request URL", bundle: .resources)
        }
    }

    private nonisolated static func describe(_ error: OrcaLauncherError) -> String {
        switch error {
        case .unsupportedSubject: String(localized: "Orca can only start agents for pull requests", bundle: .resources)
        case .notBound(let repo): String(localized: "\(repo) is not linked to an Orca repository", bundle: .resources)
        case .agentNotConfigured: String(localized: "No agent is set for the Orca launcher", bundle: .resources)
        case .invalidSettings(let path): String(localized: "The Orca launcher settings are invalid at \(path)", bundle: .resources)
        case .repoNotFound(let id): String(localized: "Orca repository \(id) was not found", bundle: .resources)
        case .headCheckedOutInMainWorktree(let branch):
            String(localized: "The branch \(branch) is checked out in the repository's main folder", bundle: .resources)
        case .branchMismatch(let expected, let actual):
            String(localized: "Orca created branch \(actual) instead of \(expected)", bundle: .resources)
        case .diverged(let branch): String(localized: "The local branch \(branch) and the pull request have diverged", bundle: .resources)
        case .chatSurface: String(localized: "Orca started the agent as a chat instead of a terminal", bundle: .resources)
        case .promptNotHanded(let outcome): String(localized: "Orca did not hand the instructions to the agent (\(outcome))", bundle: .resources)
        case .sendNotAccepted: String(localized: "The running agent did not accept the instructions", bundle: .resources)
        case .notRunning: String(localized: "Orca is not running", bundle: .resources)
        case .commandFailed(let message): message
        }
    }

    private nonisolated static func describe(_ error: ScriptLauncherError) -> String {
        switch error {
        case .missingExecutable: String(localized: "The script launcher has no executable set", bundle: .resources)
        case .failed(let code, let tail):
            String(localized: "The launcher script exited with code \(code)", bundle: .resources) + (tail.isEmpty ? "" : "\n\(tail)")
        case .timedOut: String(localized: "The launcher script timed out", bundle: .resources)
        case .invalidOutput(let output): String(localized: "The launcher script printed invalid output: \(output)", bundle: .resources)
        }
    }

    private nonisolated static func describe(_ error: ConfigStoreError) -> String {
        switch error {
        case .corrupt(let path, _): String(localized: "The settings file is damaged: \(path)", bundle: .resources)
        case .noBackup: String(localized: "No backup of the settings file is available", bundle: .resources)
        case .newerSchema:
            String(localized: "The settings file was saved by a newer version of Pilotboat. Update Pilotboat to use it", bundle: .resources)
        }
    }
}
