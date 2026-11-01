import Foundation

public enum PromptRenderer {
    public static let commonVariables = [
        "pr.url", "pr.number", "pr.title", "pr.headRef", "pr.baseRef", "pr.author", "repo.fullName", "event.kind",
    ]
    public static let reviewVariables = ["review.author", "review.state", "review.isBot", "review.count"]
    /// Variables whose values a third party controls, so using them allows prompt injection.
    public static let untrustedVariables: Set<String> = ["pr.title"]

    public static func variables(for kind: EventKind) -> [String] {
        kind == .reviewSubmitted ? commonVariables + reviewVariables : commonVariables
    }

    public static func referencedVariables(in template: String) -> [String] {
        var seen = Set<String>()
        return template.matches(of: pattern).map { String($0.output.1) }.filter { seen.insert($0).inserted }
    }

    /// Variable names that are unknown or not available for `kind`.
    public static func validate(template: String, kind: EventKind) -> [String] {
        let allowed = Set(variables(for: kind))
        return referencedVariables(in: template).filter { !allowed.contains($0) }
    }

    public static func usesUntrustedVariables(_ template: String) -> Bool {
        referencedVariables(in: template).contains(where: untrustedVariables.contains)
    }

    /// `review.*` come from the newest event carrying a review; unresolved variables are left as written.
    public static func render(template: String, events: [Event]) -> String {
        let ordered = events.sorted { $0.occurredAt < $1.occurredAt }
        guard let latest = ordered.last else { return template }
        var values: [String: String] = ["event.kind": latest.kind.rawValue, "repo.fullName": latest.repo]
        if let pr = latest.subject.pullRequest {
            values["pr.url"] = pr.url.absoluteString
            values["pr.number"] = String(pr.number)
            values["pr.title"] = pr.title
            values["pr.headRef"] = pr.headRef
            values["pr.baseRef"] = pr.baseRef
            values["pr.author"] = pr.author
            values["repo.fullName"] = pr.repo
        }
        if latest.kind == .reviewSubmitted {
            values["review.count"] = String(events.count)
            if let review = ordered.last(where: { $0.review != nil }) {
                values["review.author"] = review.actor?.login
                values["review.state"] = review.review?.state
                values["review.isBot"] = review.actor.map { String($0.isBot) }
            }
        }
        return template.replacing(pattern) { match in values[String(match.output.1)] ?? String(match.output.0) }
    }

    nonisolated(unsafe) private static let pattern = /\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/
}
