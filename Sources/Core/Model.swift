import Foundation

/// Struct instead of enum so a config file containing a kind from a newer
/// app version still decodes; such rules are shown as unsupported.
public struct EventKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let reviewRequested = EventKind(rawValue: "reviewRequested")
    public static let reviewSubmitted = EventKind(rawValue: "reviewSubmitted")
    public static let supported: Set<EventKind> = [.reviewRequested, .reviewSubmitted]

    public var isSupported: Bool { Self.supported.contains(self) }
}

public enum PullRequestState: String, Codable, Sendable {
    case open = "OPEN", closed = "CLOSED", merged = "MERGED"
}

public struct PullRequestRef: Codable, Hashable, Sendable {
    public var host: String
    public var repo: String
    public var number: Int
    public var url: URL
    public var title: String
    public var headRef: String
    public var headSHA: String
    public var baseRef: String
    public var isDraft: Bool
    public var isCrossRepository: Bool
    public var labels: [String]
    public var author: String
    public var state: PullRequestState

    public init(host: String, repo: String, number: Int, url: URL, title: String, headRef: String, headSHA: String, baseRef: String, isDraft: Bool, isCrossRepository: Bool, labels: [String], author: String, state: PullRequestState = .open) {
        self.host = host; self.repo = repo; self.number = number; self.url = url; self.title = title
        self.headRef = headRef; self.headSHA = headSHA; self.baseRef = baseRef; self.isDraft = isDraft
        self.isCrossRepository = isCrossRepository; self.labels = labels; self.author = author; self.state = state
    }

    /// `state` defaults to `.open` for snapshots stored before it existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(host: try c.decode(String.self, forKey: .host), repo: try c.decode(String.self, forKey: .repo),
                  number: try c.decode(Int.self, forKey: .number), url: try c.decode(URL.self, forKey: .url),
                  title: try c.decode(String.self, forKey: .title), headRef: try c.decode(String.self, forKey: .headRef),
                  headSHA: try c.decode(String.self, forKey: .headSHA), baseRef: try c.decode(String.self, forKey: .baseRef),
                  isDraft: try c.decode(Bool.self, forKey: .isDraft), isCrossRepository: try c.decode(Bool.self, forKey: .isCrossRepository),
                  labels: try c.decode([String].self, forKey: .labels), author: try c.decode(String.self, forKey: .author),
                  state: try c.decodeIfPresent(PullRequestState.self, forKey: .state) ?? .open)
    }
}

public enum Subject: Codable, Hashable, Sendable {
    case pullRequest(PullRequestRef)

    private enum CodingKeys: String, CodingKey { case type, pullRequest }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "pullRequest": self = .pullRequest(try c.decode(PullRequestRef.self, forKey: .pullRequest))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown subject \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pullRequest(let pr): try c.encode("pullRequest", forKey: .type); try c.encode(pr, forKey: .pullRequest)
        }
    }

    public var pullRequest: PullRequestRef? {
        if case .pullRequest(let pr) = self { return pr }
        return nil
    }
}

public struct Actor: Codable, Hashable, Sendable {
    public var login: String
    public var isBot: Bool
    public init(login: String, isBot: Bool) { self.login = login; self.isBot = isBot }
}

public struct Event: Codable, Hashable, Sendable {
    public var kind: EventKind
    public var repo: String
    public var subject: Subject
    public var actor: Actor?
    public var occurredAt: Date
    public var dedupeKey: String
    public var review: ReviewInfo?

    public init(kind: EventKind, repo: String, subject: Subject, actor: Actor? = nil, occurredAt: Date, dedupeKey: String, review: ReviewInfo? = nil) {
        self.kind = kind; self.repo = repo; self.subject = subject; self.actor = actor
        self.occurredAt = occurredAt; self.dedupeKey = dedupeKey; self.review = review
    }
}

public struct ReviewInfo: Codable, Hashable, Sendable {
    public var id: Int
    public var state: String
    public init(id: Int, state: String) { self.id = id; self.state = state }
}

public typealias LauncherID = String

public struct Repository: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var host: String
    public var fullName: String
    public var monitoring: Bool
    public var mutedEventKinds: Set<EventKind>
    public var launcherBindings: [LauncherID: String]

    public init(id: UUID = UUID(), host: String = Repository.defaultHost, fullName: String, monitoring: Bool = true, mutedEventKinds: Set<EventKind> = [], launcherBindings: [LauncherID: String] = [:]) {
        self.id = id; self.host = host; self.fullName = fullName; self.monitoring = monitoring
        self.mutedEventKinds = mutedEventKinds; self.launcherBindings = launcherBindings
    }
}

public enum RepoScope: Codable, Hashable, Sendable {
    case all
    case only([UUID])

    private enum CodingKeys: String, CodingKey { case type, repositoryIds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "all": self = .all
        case "only": self = .only(try c.decode([UUID].self, forKey: .repositoryIds))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown repoScope \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all: try c.encode("all", forKey: .type)
        case .only(let ids):
            try c.encode("only", forKey: .type)
            try c.encode(ids, forKey: .repositoryIds)
        }
    }

    public func contains(_ repo: Repository) -> Bool {
        switch self {
        case .all: return true
        case .only(let ids): return ids.contains(repo.id)
        }
    }
}

public enum WorkspacePolicy: String, Codable, Sendable {
    case alwaysNew
    case reuseOrCreate
    case reusePrevious
}

public enum ActorKind: String, Codable, Sendable {
    case bot, human, any
}

public enum Condition: Codable, Hashable, Sendable {
    case actorKind(ActorKind)
    case includeDraft(Bool)
    case labelsInclude([String])
    case labelsExclude([String])

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "actorKind": self = .actorKind(try c.decode(ActorKind.self, forKey: .value))
        case "includeDraft": self = .includeDraft(try c.decode(Bool.self, forKey: .value))
        case "labelsInclude": self = .labelsInclude(try c.decode([String].self, forKey: .value))
        case "labelsExclude": self = .labelsExclude(try c.decode([String].self, forKey: .value))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown condition \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .actorKind(let v): try c.encode("actorKind", forKey: .type); try c.encode(v, forKey: .value)
        case .includeDraft(let v): try c.encode("includeDraft", forKey: .type); try c.encode(v, forKey: .value)
        case .labelsInclude(let v): try c.encode("labelsInclude", forKey: .type); try c.encode(v, forKey: .value)
        case .labelsExclude(let v): try c.encode("labelsExclude", forKey: .type); try c.encode(v, forKey: .value)
        }
    }
}

public enum ExecutionMode: String, Codable, Sendable {
    case auto, confirm
}

public struct Rule: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var priority: Int
    public var eventKind: EventKind
    public var repoScope: RepoScope
    public var conditions: [Condition]
    public var settleSeconds: Int
    public var launcherId: LauncherID
    public var workspacePolicy: WorkspacePolicy
    public var promptTemplateId: String
    public var executionMode: ExecutionMode

    public init(id: String = UUID().uuidString, name: String, enabled: Bool = false, priority: Int, eventKind: EventKind, repoScope: RepoScope = .all, conditions: [Condition] = [], settleSeconds: Int, launcherId: LauncherID, workspacePolicy: WorkspacePolicy, promptTemplateId: String, executionMode: ExecutionMode = .auto) {
        self.id = id; self.name = name; self.enabled = enabled; self.priority = priority; self.eventKind = eventKind
        self.repoScope = repoScope; self.conditions = conditions; self.settleSeconds = settleSeconds; self.launcherId = launcherId
        self.workspacePolicy = workspacePolicy; self.promptTemplateId = promptTemplateId; self.executionMode = executionMode
    }
}

public struct PromptTemplate: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var body: String
    public init(id: String = UUID().uuidString, name: String, body: String) { self.id = id; self.name = name; self.body = body }
}

public struct LauncherConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: LauncherID
    public var type: String
    public var settings: JSONValue
    public init(id: LauncherID, type: String, settings: JSONValue = .object([:])) { self.id = id; self.type = type; self.settings = settings }
}

public enum RunState: String, Codable, Sendable {
    case settling, pendingApproval, queued, held, launching, launched, failed, skipped
}

public enum SkipReason: String, Codable, Sendable {
    case userSkipped, approvalTimeout, prClosed, monitoringOff, ruleRemoved, crossRepository
}

public struct RunSnapshot: Codable, Hashable, Sendable {
    public var launcherId: LauncherID
    public var workspacePolicy: WorkspacePolicy
    public var renderedPrompt: String
    public var subject: Subject
    public init(launcherId: LauncherID, workspacePolicy: WorkspacePolicy, renderedPrompt: String, subject: Subject) {
        self.launcherId = launcherId; self.workspacePolicy = workspacePolicy; self.renderedPrompt = renderedPrompt; self.subject = subject
    }
}

public struct Run: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var state: RunState
    public var skipReason: SkipReason?
    public var ruleId: String
    public var repo: String
    public var prNumber: Int
    public var settleUntil: Date?
    public var snapshot: RunSnapshot?
    public var workspaceRef: String?
    public var terminalHandle: String?
    public var retryToken: String?
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var launchedAt: Date?

    public init(id: UUID = UUID(), state: RunState, skipReason: SkipReason? = nil, ruleId: String, repo: String, prNumber: Int, settleUntil: Date? = nil, snapshot: RunSnapshot? = nil, workspaceRef: String? = nil, terminalHandle: String? = nil, retryToken: String? = nil, error: String? = nil, createdAt: Date, updatedAt: Date, launchedAt: Date? = nil) {
        self.id = id; self.state = state; self.skipReason = skipReason; self.ruleId = ruleId; self.repo = repo; self.prNumber = prNumber
        self.settleUntil = settleUntil; self.snapshot = snapshot; self.workspaceRef = workspaceRef; self.terminalHandle = terminalHandle
        self.retryToken = retryToken; self.error = error; self.createdAt = createdAt; self.updatedAt = updatedAt; self.launchedAt = launchedAt
    }
}
