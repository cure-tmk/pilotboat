import Core
import Foundation
import os

let sourceLogger = Logger(subsystem: "io.github.cure-tmk.pilotboat", category: "source")

public actor GitHubSource: EventSource {
    public static let typeID = "github"
    public nonisolated let supportedKinds: Set<EventKind> = [.reviewRequested, .reviewSubmitted]
    public nonisolated let host: String
    private let secretStore: any SecretStore
    private let session: URLSession
    private let time: any TimeSource
    private let includeTeamReviewRequests: @Sendable () -> Bool
    private let excludedActors: @Sendable () -> [String]
    public private(set) var lastRateLimit: RateLimitInfo?

    public init(host: String = "github.com", secretStore: any SecretStore, session: URLSession = .shared, time: any TimeSource, includeTeamReviewRequests: @escaping @Sendable () -> Bool, excludedActors: @escaping @Sendable () -> [String]) {
        self.host = host; self.secretStore = secretStore; self.session = session; self.time = time
        self.includeTeamReviewRequests = includeTeamReviewRequests; self.excludedActors = excludedActors
    }

    public func poll(context: SourceContext) async throws -> PollResult {
        let start = time.now
        if let rl = lastRateLimit, rl.isLow, rl.resetAt > start { throw GitHubError.rateLimited(until: rl.resetAt) }
        let client = try makeClient()
        let monitored = Set(context.repositories.filter { $0.monitoring && $0.host == host }.map { $0.fullName.lowercased() })
        func isMonitored(_ node: PRNode) -> Bool { monitored.contains(node.repository.nameWithOwner.lowercased()) }

        var events: [Event] = []
        var open: [PullRequestRef] = []

        if context.requestedKinds.contains(.reviewRequested) {
            let includeTeams = includeTeamReviewRequests()
            let q = "is:pr is:open archived:false \(includeTeams ? "review-requested" : "user-review-requested"):@me"
            let (viewer, nodes) = try await search(client, Self.reviewRequestedQuery, q: q)
            for node in nodes where isMonitored(node) {
                let pr = node.ref(host: host)
                open.append(pr)
                let requestedAt = node.timelineItems?.nodes.compactMap { item -> Date? in
                    guard let reviewer = item.requestedReviewer else { return nil }
                    let matches = reviewer.typename == "User" ? reviewer.login?.caseInsensitiveCompare(viewer) == .orderedSame : (includeTeams && reviewer.typename == "Team")
                    return matches ? item.createdAt : nil
                }.max()
                guard let requestedAt else {
                    sourceLogger.warning("No ReviewRequestedEvent for \(pr.repo, privacy: .public)#\(pr.number); skipped")
                    continue
                }
                events.append(Event(kind: .reviewRequested, repo: pr.repo, subject: .pullRequest(pr), occurredAt: requestedAt,
                                    dedupeKey: "rr:\(host)/\(pr.repo)#\(pr.number):\(requestedAt.formatted(.iso8601))"))
            }
        }

        if context.requestedKinds.contains(.reviewSubmitted) {
            let since = (context.cursor ?? start).addingTimeInterval(-5 * 60)
            let q = "is:pr is:open archived:false author:@me updated:>=\(since.formatted(.iso8601))"
            let (viewer, nodes) = try await search(client, Self.reviewSubmittedQuery, q: q)
            let ignored = Set(([viewer] + excludedActors()).map { $0.lowercased() })
            for node in nodes where isMonitored(node) {
                let pr = node.ref(host: host)
                for review in node.reviews?.nodes ?? [] {
                    guard review.state != "PENDING", let id = review.databaseId, let submittedAt = review.submittedAt, submittedAt > since else { continue }
                    let login = review.author?.login ?? "ghost"
                    guard !ignored.contains(login.lowercased()) else { continue }
                    events.append(Event(kind: .reviewSubmitted, repo: pr.repo, subject: .pullRequest(pr),
                                        actor: Actor(login: login, isBot: review.author?.typename == "Bot"),
                                        occurredAt: submittedAt, dedupeKey: "rs:\(host)/\(pr.repo)#\(pr.number):\(id)",
                                        review: ReviewInfo(id: id, state: review.state)))
                }
            }
        }

        return PollResult(events: events, cursor: start, openReviewRequests: open, rateLimitRemaining: lastRateLimit?.remaining)
    }

    public func pullRequest(url: URL) async throws -> PullRequestRef {
        let parts = url.pathComponents
        guard url.host()?.lowercased() == host.lowercased(), parts.count >= 5, parts[3] == "pull", let number = Int(parts[4]) else {
            throw GitHubError.invalidURL
        }
        struct Response: Decodable {
            struct Repo: Decodable { let pullRequest: PRNode? }
            let repository: Repo?
            let rateLimit: RateLimitInfo?
        }
        let r: Response = try await makeClient().query(Self.pullRequestQuery, variables: ["owner": parts[1], "name": parts[2], "number": number])
        record(r.rateLimit)
        guard let node = r.repository?.pullRequest else { throw GitHubError.graphQL(["Pull request not found"]) }
        return node.ref(host: host)
    }

    public func diagnose() async -> [DiagnosticItem] {
        let title = "GitHub (\(host))"
        do {
            let login = try await viewerLogin(makeClient())
            var items = [DiagnosticItem(level: .ok, title: title, detail: "Signed in as \(login)")]
            if let rl = lastRateLimit, rl.isLow {
                items.append(DiagnosticItem(level: .warning, title: "GitHub rate limit", detail: "\(rl.remaining) of \(rl.limit) remaining"))
            }
            return items
        } catch {
            return [DiagnosticItem(level: .error, title: title, detail: TokenMasker.mask(error.localizedDescription))]
        }
    }

    public func verifyToken(_ token: String) async throws -> String {
        try await viewerLogin(GraphQLClient(host: host, token: token, session: session, now: { [time] in time.now }))
    }

    private func viewerLogin(_ client: GraphQLClient) async throws -> String {
        struct Response: Decodable { let viewer: Login; let rateLimit: RateLimitInfo? }
        let r: Response = try await client.query("query { viewer { login } rateLimit { limit remaining resetAt } }")
        lastRateLimit = r.rateLimit
        return r.viewer.login
    }

    private func makeClient() throws -> GraphQLClient {
        let token: String?
        do { token = try secretStore.token(host: host) } catch { throw GitHubError.noToken }
        guard let token, !token.isEmpty else { throw GitHubError.noToken }
        return GraphQLClient(host: host, token: token, session: session, now: { [time] in time.now })
    }

    private func record(_ rateLimit: RateLimitInfo?) {
        if let rateLimit { lastRateLimit = rateLimit }
    }

    private func search(_ client: GraphQLClient, _ query: String, q: String) async throws -> (viewer: String, nodes: [PRNode]) {
        struct Response: Decodable {
            struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
            struct Search: Decodable { let pageInfo: PageInfo; let nodes: [PRNode] }
            let viewer: Login
            let rateLimit: RateLimitInfo?
            let search: Search
        }
        var after: String?
        var nodes: [PRNode] = []
        var viewer = ""
        repeat {
            let r: Response = try await client.query(query, variables: ["q": q, "after": after])
            record(r.rateLimit)
            viewer = r.viewer.login
            nodes += r.search.nodes
            after = r.search.pageInfo.hasNextPage ? r.search.pageInfo.endCursor : nil
        } while after != nil
        return (viewer, nodes)
    }

    private static let prFragment = """
    fragment PR on PullRequest {
      number url title state isDraft isCrossRepository
      headRefName headRefOid baseRefName
      author { __typename login }
      repository { nameWithOwner }
      labels(first: 20) { nodes { name } }
    }
    """

    static func searchQuery(extraFields: String) -> String {
        """
        query($q: String!, $after: String) {
          viewer { login }
          rateLimit { limit remaining resetAt }
          search(type: ISSUE, query: $q, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on PullRequest {
              ...PR
              \(extraFields)
            } }
          }
        }
        """ + prFragment
    }

    static let reviewRequestedQuery = searchQuery(extraFields: """
    timelineItems(last: 20, itemTypes: [REVIEW_REQUESTED_EVENT]) {
      nodes { ... on ReviewRequestedEvent {
        createdAt
        requestedReviewer { __typename ... on User { login } ... on Team { slug } }
      } }
    }
    """)

    static let reviewSubmittedQuery = searchQuery(extraFields: "reviews(last: 50) { nodes { databaseId state submittedAt author { __typename login } } }")

    static let pullRequestQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      rateLimit { limit remaining resetAt }
      repository(owner: $owner, name: $name) { pullRequest(number: $number) { ...PR } }
    }
    """ + prFragment
}

private struct Login: Decodable { let login: String }

private struct Author: Decodable {
    let typename: String?
    let login: String?
    let slug: String?
    enum CodingKeys: String, CodingKey { case typename = "__typename", login, slug }
}

private struct PRNode: Decodable, Sendable {
    struct Repo: Decodable { let nameWithOwner: String }
    struct Nodes<T: Decodable & Sendable>: Decodable, Sendable { let nodes: [T] }
    struct Label: Decodable { let name: String }
    struct TimelineItem: Decodable { let createdAt: Date?; let requestedReviewer: Author? }
    struct Review: Decodable { let databaseId: Int?; let state: String; let submittedAt: Date?; let author: Author? }

    let number: Int
    let url: URL
    let title: String
    let state: PullRequestState
    let isDraft: Bool
    let isCrossRepository: Bool
    let headRefName: String
    let headRefOid: String
    let baseRefName: String
    let author: Author?
    let repository: Repo
    let labels: Nodes<Label>?
    let timelineItems: Nodes<TimelineItem>?
    let reviews: Nodes<Review>?

    func ref(host: String) -> PullRequestRef {
        PullRequestRef(host: host, repo: repository.nameWithOwner, number: number, url: url, title: title, headRef: headRefName,
                       headSHA: headRefOid, baseRef: baseRefName, isDraft: isDraft, isCrossRepository: isCrossRepository,
                       labels: labels?.nodes.map(\.name) ?? [], author: author?.login ?? "ghost", state: state)
    }
}
