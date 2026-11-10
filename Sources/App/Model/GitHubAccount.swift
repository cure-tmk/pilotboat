import Core
import Foundation
import Observation
import ProcessKit
import SourceGitHub

@MainActor @Observable
final class GitHubAccount {
    private(set) var login: String?
    let ghAvailable: Bool
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let github: GitHubSource
    @ObservationIgnored private let secretStore: any SecretStore
    @ObservationIgnored private let runner: any CommandRunner
    private let host = Repository.defaultHost

    init(github: GitHubSource, secretStore: any SecretStore, runner: any CommandRunner, searchPath: [String]) {
        self.github = github; self.secretStore = secretStore; self.runner = runner
        ghAvailable = PathResolver.find("gh", in: searchPath) != nil
    }

    func restore() async {
        let host = host
        guard let token = try? await keychain({ try $0.token(host: host) }) else { return }
        login = try? await github.verifyToken(token)
    }

    @discardableResult
    func signIn(token: String) async throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = host
        let login: String
        do {
            login = try await github.verifyToken(token)
            try await keychain { try $0.setToken(token, host: host) }
        } catch {
            throw AppError(AppModel.describe(error))
        }
        self.login = login
        await model?.triggerTick()
        return login
    }

    @discardableResult
    func signInWithGhCLI() async throws -> String {
        let result: CommandResult
        do { result = try await runner.run(Command("gh", ["auth", "token", "--hostname", host], timeout: 10)) }
        catch { throw AppError(AppModel.describe(error)) }
        guard result.succeeded, !result.stdoutText.isEmpty else {
            throw AppError(String(localized: "Could not get a token from gh: \(TokenMasker.mask(result.errorTail))", bundle: .resources))
        }
        return try await signIn(token: result.stdoutText)
    }

    func signOut() async {
        let host = host
        do {
            try await keychain { try $0.removeToken(host: host) }
            login = nil
        } catch {
            model?.report(error)
        }
    }

    // Keychain calls can block on a user prompt; keep them off the main thread so the UI stays responsive.
    private func keychain<T: Sendable>(_ body: @escaping @Sendable (any SecretStore) throws -> T) async throws -> T {
        let store = secretStore
        return try await Task.detached { try body(store) }.value
    }
}
