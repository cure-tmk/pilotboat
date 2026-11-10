import Foundation

public struct DiagnosticItem: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable { case ok, warning, error }
    public var level: Level
    public var title: String
    public var detail: String?
    public init(level: Level, title: String, detail: String? = nil) { self.level = level; self.title = title; self.detail = detail }
}

public struct SourceContext: Sendable {
    public var repositories: [Repository]
    public var requestedKinds: Set<EventKind>
    public var cursor: Date?
    public init(repositories: [Repository], requestedKinds: Set<EventKind>, cursor: Date?) {
        self.repositories = repositories; self.requestedKinds = requestedKinds; self.cursor = cursor
    }
}

public struct PollResult: Sendable {
    public var events: [Event]
    public var cursor: Date
    /// Open PRs currently requesting the viewer's review, for the menu bar count and trial runs.
    public var openReviewRequests: [PullRequestRef]
    public var rateLimitRemaining: Int?
    public init(events: [Event], cursor: Date, openReviewRequests: [PullRequestRef] = [], rateLimitRemaining: Int? = nil) {
        self.events = events; self.cursor = cursor; self.openReviewRequests = openReviewRequests; self.rateLimitRemaining = rateLimitRemaining
    }
}

public protocol EventSource: Sendable {
    static var typeID: String { get }
    var supportedKinds: Set<EventKind> { get }
    func poll(context: SourceContext) async throws -> PollResult
    /// Resolves a PR URL for prompt previews and trial runs.
    func pullRequest(url: URL) async throws -> PullRequestRef
    func diagnose() async -> [DiagnosticItem]
}

public struct LauncherCapabilities: OptionSet, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let reuseWorkspace = LauncherCapabilities(rawValue: 1 << 0)
    public static let sendToSession = LauncherCapabilities(rawValue: 1 << 1)
}

public struct RepositoryInfo: Codable, Hashable, Sendable {
    public var host: String
    public var fullName: String
    public var launcherBinding: String?
    public init(host: String, fullName: String, launcherBinding: String?) { self.host = host; self.fullName = fullName; self.launcherBinding = launcherBinding }
}

public struct LaunchRequest: Codable, Sendable {
    public var runId: UUID
    public var subject: Subject
    public var repository: RepositoryInfo
    public var workspacePolicy: WorkspacePolicy
    public var prompt: String
    public var previousWorkspaceRef: String?
    public var previousTerminalHandle: String?
    public var launcherSettings: JSONValue
    public var retryToken: String?
    public init(runId: UUID, subject: Subject, repository: RepositoryInfo, workspacePolicy: WorkspacePolicy, prompt: String, previousWorkspaceRef: String? = nil, previousTerminalHandle: String? = nil, launcherSettings: JSONValue, retryToken: String? = nil) {
        self.runId = runId; self.subject = subject; self.repository = repository; self.workspacePolicy = workspacePolicy; self.prompt = prompt
        self.previousWorkspaceRef = previousWorkspaceRef; self.previousTerminalHandle = previousTerminalHandle; self.launcherSettings = launcherSettings
        self.retryToken = retryToken
    }
}

public struct LaunchResult: Codable, Sendable {
    public var workspaceRef: String
    public var terminalHandle: String?
    public var reusedWorkspace: Bool
    public var sentToExistingSession: Bool
    public var retryToken: String?
    public init(workspaceRef: String, terminalHandle: String? = nil, reusedWorkspace: Bool = false, sentToExistingSession: Bool = false, retryToken: String? = nil) {
        self.workspaceRef = workspaceRef; self.terminalHandle = terminalHandle; self.reusedWorkspace = reusedWorkspace; self.sentToExistingSession = sentToExistingSession
        self.retryToken = retryToken
    }
}

/// A launch failure the launcher can resume; the engine stores `retryToken` on the run and hands it back on retry.
public protocol RetryableLaunchError: Error {
    var retryToken: String { get }
}

public protocol Launcher: Sendable {
    static var typeID: String { get }
    /// What the launcher configured with `settings` supports; reuse policies fall back to `alwaysNew` without `.reuseWorkspace`.
    func capabilities(settings: JSONValue) async -> LauncherCapabilities
    func launch(_ request: LaunchRequest) async throws -> LaunchResult
    /// Human-readable description of what `launch` would run, without side effects (dry run).
    func describe(_ request: LaunchRequest) async -> String
    func diagnose(settings: JSONValue) async -> [DiagnosticItem]
    func open(_ workspaceRef: String, settings: JSONValue) async throws
}
