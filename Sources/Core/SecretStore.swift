public protocol SecretStore: Sendable {
    func token(host: String) throws -> String?
    func setToken(_ token: String, host: String) throws
    func removeToken(host: String) throws
}

import Foundation

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String]
    public init(tokens: [String: String] = [:]) { self.tokens = tokens }
    public func token(host: String) throws -> String? { lock.withLock { tokens[host] } }
    public func setToken(_ token: String, host: String) throws { lock.withLock { tokens[host] = token } }
    public func removeToken(host: String) throws { lock.withLock { tokens[host] = nil } }
}
