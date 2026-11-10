import Core
import Foundation
@testable import SourceGitHub

struct StubResponse {
    var status = 200
    var headers: [String: String] = [:]
    var body: Any = [String: Any]()
    var failure: URLError?
}

final class Stub: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]

    let token = "ghp_test\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    private let handler: @Sendable ([String: Any]) -> StubResponse
    private(set) var requests: [[String: Any]] = []
    private(set) var timeouts: [TimeInterval] = []
    private(set) var endpoints: [URL] = []

    init(_ handler: @escaping @Sendable ([String: Any]) -> StubResponse) {
        self.handler = handler
        Self.lock.withLock { Self.stubs[token] = self }
    }

    var requestTimeouts: [TimeInterval] { Self.lock.withLock { timeouts } }
    var urls: [URL] { Self.lock.withLock { endpoints } }
    var queries: [String] { Self.lock.withLock { requests.map { $0["query"] as! String } } }
    var variables: [[String: Any]] { Self.lock.withLock { requests.map { $0["variables"] as! [String: Any] } } }

    static func handle(_ request: URLRequest) -> StubResponse {
        let token = request.value(forHTTPHeaderField: "Authorization")!.replacingOccurrences(of: "bearer ", with: "")
        let stub = lock.withLock { stubs[token]! }
        let body = try! JSONSerialization.jsonObject(with: readBody(request)) as! [String: Any]
        lock.withLock { stub.requests.append(body); stub.timeouts.append(request.timeoutInterval); stub.endpoints.append(request.url!) }
        return stub.handler(body)
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        let stream = request.httpBodyStream!
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let r = Stub.handle(request)
        if let failure = r.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: r.body))
        client?.urlProtocolDidFinishLoading(self)
    }
}

struct FixedTime: TimeSource { var now: Date }

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func iso(_ d: Date) -> String { d.formatted(.iso8601) }

func makeSource(_ stub: Stub, host: String = "github.com", includeTeams: Bool = false, excluded: [String] = [], tokens: Bool = true, now: Date = t0) -> GitHubSource {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return GitHubSource(host: host, secretStore: InMemorySecretStore(tokens: tokens ? [host: stub.token] : [:]),
                        session: URLSession(configuration: config), time: FixedTime(now: now),
                        includeTeamReviewRequests: { includeTeams }, excludedActors: { excluded })
}

func context(_ kinds: Set<EventKind> = [.reviewRequested, .reviewSubmitted], repos: [Repository] = [Repository(fullName: "acme/app")], cursor: Date? = nil) -> SourceContext {
    SourceContext(repositories: repos, requestedKinds: kinds, cursor: cursor)
}

func pr(_ number: Int, repo: String = "acme/app", author: String = "me", state: String = "OPEN", timeline: [[String: Any]]? = nil, reviews: [[String: Any]]? = nil) -> [String: Any] {
    var node: [String: Any] = [
        "number": number, "url": "https://github.com/\(repo)/pull/\(number)", "title": "PR \(number)", "state": state,
        "isDraft": false, "isCrossRepository": false, "headRefName": "feature-\(number)", "headRefOid": "sha\(number)",
        "baseRefName": "main", "author": ["__typename": "User", "login": author], "repository": ["nameWithOwner": repo],
        "labels": ["nodes": [["name": "bug"]]],
    ]
    if let timeline { node["timelineItems"] = ["nodes": timeline] }
    if let reviews { node["reviews"] = ["nodes": reviews] }
    return node
}

func requested(_ at: Date, user: String? = nil, team: String? = nil) -> [String: Any] {
    let reviewer: [String: Any] = user.map { ["__typename": "User", "login": $0] } ?? ["__typename": "Team", "slug": team!]
    return ["createdAt": iso(at), "requestedReviewer": reviewer]
}

func review(_ id: Int, by login: String, at: Date?, state: String = "APPROVED", bot: Bool = false) -> [String: Any] {
    ["databaseId": id, "state": state, "submittedAt": at.map(iso) as Any? ?? NSNull(),
     "author": ["__typename": bot ? "Bot" : "User", "login": login]]
}

func searchPage(_ nodes: [[String: Any]], viewer: String = "me", next: String? = nil, remaining: Int = 4900) -> StubResponse {
    StubResponse(body: ["data": [
        "viewer": ["login": viewer],
        "rateLimit": ["limit": 5000, "remaining": remaining, "resetAt": iso(t0.addingTimeInterval(3600))],
        "search": ["pageInfo": ["hasNextPage": next != nil, "endCursor": next as Any? ?? NSNull()], "nodes": nodes],
    ]])
}

func isQ1(_ body: [String: Any]) -> Bool { (body["query"] as! String).contains("timelineItems") }
