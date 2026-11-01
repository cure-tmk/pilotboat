import Foundation

public enum EngineEvent: Sendable {
    case runNeedsApproval(Run)
    case runLaunched(Run)
    case runFailed(Run)
    /// Daily launch limit reached; the run waits until the next day.
    case runHeld(Run)
    case runsChanged
    case configChanged(Config)
    case statusChanged(EngineStatus)
}

public struct EngineStatus: Hashable, Sendable {
    public enum Monitoring: Hashable, Sendable {
        case on, off
        case offUntil(Date)
    }

    public var monitoring: Monitoring
    public var lastTickAt: Date?
    public var lastError: String?
    public var openReviewRequests: [PullRequestRef] = []
    public var consecutiveFailures = 0
    public var rateLimitRemaining: Int?
}

public enum TickOutcome: Hashable, Sendable {
    case completed
    /// Polling was skipped; `until` is when monitoring resumes on its own.
    case monitoringOff(until: Date?)
    case failed(consecutiveFailures: Int)
    /// Another tick was still running.
    case busy
}

public struct DryRunReport: Sendable {
    public var pullRequest: PullRequestRef
    /// `nil` when the rule would fire.
    public var mismatch: RuleMismatch?
    /// The rule that would actually fire for this PR, if any.
    public var winningRule: Rule?
    public var renderedPrompt: String
    public var launcherDescription: String
}

public enum EngineError: Error, Hashable, Sendable {
    case ruleNotFound(String)
    case templateNotFound(String)
    case launcherNotFound(LauncherID)
    case noSourceForHost(String)
    case runNotFound(UUID)
    case invalidTransition(from: RunState)
    case unsupportedSubject
}
