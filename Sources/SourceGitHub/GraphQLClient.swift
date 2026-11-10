import Foundation

public enum GitHubError: LocalizedError {
    case noToken
    case unauthorized
    case ssoRequired(orgs: [String])
    case rateLimited(until: Date)
    case http(status: Int, body: String)
    case graphQL([String])
    case network(Error)
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .noToken: "GitHub token is not set"
        case .unauthorized: "GitHub token is invalid or expired"
        case .ssoRequired(let orgs) where orgs.isEmpty: "Authorize the token for SAML SSO"
        case .ssoRequired(let orgs): "Authorize the token for SAML SSO: \(orgs.joined(separator: ", "))"
        case .rateLimited(let until): "GitHub rate limit reached until \(until.formatted(.iso8601))"
        case .http(let status, _): "GitHub returned HTTP \(status)"
        case .graphQL(let messages): TokenMasker.mask(messages.joined(separator: "; "))
        case .network(let error): TokenMasker.mask(error.localizedDescription)
        case .invalidURL: "Not a pull request URL"
        }
    }
}

public struct RateLimitInfo: Decodable, Hashable, Sendable {
    public var limit: Int
    public var remaining: Int
    public var resetAt: Date
    public var isLow: Bool { remaining < limit / 10 }
}

public enum TokenMasker {
    public static func mask(_ text: String) -> String {
        text.replacing(/gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+/, with: "[REDACTED]")
    }
}

struct GraphQLClient: Sendable {
    let endpoint: URL
    let token: String
    let session: URLSession
    let now: @Sendable () -> Date

    init(host: String, token: String, session: URLSession, now: @escaping @Sendable () -> Date) {
        endpoint = URL(string: host == "github.com" ? "https://api.github.com/graphql" : "https://\(host)/api/graphql")!
        self.token = token; self.session = session; self.now = now
    }

    private struct Envelope<T: Decodable>: Decodable {
        struct Message: Decodable { let message: String }
        let data: T?
        let errors: [Message]?
    }

    func query<T: Decodable>(_ query: String, variables: [String: Any?] = [:]) async throws -> T {
        let (data, _) = try await send(query, variables: variables)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope<T>.self, from: data)
        if let errors = envelope.errors, !errors.isEmpty {
            let messages = errors.map { TokenMasker.mask($0.message) }
            guard envelope.data != nil else { throw GitHubError.graphQL(messages) }
            sourceLogger.warning("GraphQL partial errors: \(messages.joined(separator: "; "), privacy: .public)")
        }
        guard let result = envelope.data else { throw GitHubError.graphQL(["empty response"]) }
        return result
    }

    func send(_ query: String, variables: [String: Any?]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Pilotboat", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables.mapValues { $0 ?? NSNull() }])

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw GitHubError.network(error) }
        guard let http = response as? HTTPURLResponse else { throw GitHubError.network(URLError(.badServerResponse)) }

        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401: throw GitHubError.unauthorized
        case 403 where http.value(forHTTPHeaderField: "X-GitHub-SSO") != nil:
            throw GitHubError.ssoRequired(orgs: Self.ssoOrgs(http.value(forHTTPHeaderField: "X-GitHub-SSO")!))
        case 403, 429:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
                throw GitHubError.rateLimited(until: Date(timeIntervalSince1970: reset))
            }
            if let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
                throw GitHubError.rateLimited(until: now().addingTimeInterval(seconds))
            }
            fallthrough
        default:
            let body = TokenMasker.mask(String(decoding: data.prefix(500), as: UTF8.self))
            sourceLogger.error("GitHub HTTP \(http.statusCode): \(body, privacy: .public)")
            throw GitHubError.http(status: http.statusCode, body: body)
        }
    }

    // Header is either `required; url=https://<host>/orgs/<org>/sso?...` or `partial-results; organizations=<id>,<id>`.
    static func ssoOrgs(_ header: String) -> [String] {
        if let match = header.firstMatch(of: /\/orgs\/([^\/]+)\/sso/) { return [String(match.1)] }
        if let match = header.firstMatch(of: /organizations=([^;\s]+)/) { return match.1.split(separator: ",").map(String.init) }
        return []
    }
}
