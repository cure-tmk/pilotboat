public protocol SecretStore: Sendable {
    func token(host: String) throws -> String?
    func setToken(_ token: String, host: String) throws
    func removeToken(host: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var tokens: [String: String]
    public init(tokens: [String: String] = [:]) { self.tokens = tokens }
    public func token(host: String) throws -> String? { tokens[host] }
    public func setToken(_ token: String, host: String) throws { tokens[host] = token }
    public func removeToken(host: String) throws { tokens[host] = nil }
}
