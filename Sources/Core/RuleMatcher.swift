import Foundation

public enum MatchOutcome: Hashable, Sendable {
    case matched(Rule)
    case repoOff
    case muted
    case noRule
}

public enum OverviewCell: Hashable, Sendable {
    case rule(Rule)
    /// Conditional rules in evaluation order; which one applies depends on the event.
    case conditional([Rule])
    case muted
    case none
    case repoOff
}

/// Why a specific rule does not fire for an event, for dry runs.
public enum RuleMismatch: Hashable, Sendable {
    case repoNotRegistered
    case repoOff
    case muted
    case ruleDisabled
    case eventKind
    case repoScope
    case condition(Condition)
    case outranked(by: Rule)
}

public enum RuleMatcher {
    /// Enabled rules applicable to `event` in `repo`, best first. Equal priority falls back to config order,
    /// which is creation order unless the user reorders rules.
    static func candidates(for event: Event, in repo: Repository, rules: [Rule]) -> [Rule] {
        ranked(rules.filter { $0.enabled && $0.eventKind == event.kind && $0.repoScope.contains(repo) && satisfies($0.conditions, event) })
    }

    public static func match(_ event: Event, in repo: Repository, config: Config) -> MatchOutcome {
        guard repo.monitoring else { return .repoOff }
        guard !repo.mutedEventKinds.contains(event.kind) else { return .muted }
        return candidates(for: event, in: repo, rules: config.rules).first.map(MatchOutcome.matched) ?? .noRule
    }

    /// `nil` when `rule` is the one that would fire.
    public static func mismatch(of rule: Rule, for event: Event, in repo: Repository?, config: Config) -> RuleMismatch? {
        guard let repo else { return .repoNotRegistered }
        guard repo.monitoring else { return .repoOff }
        guard !repo.mutedEventKinds.contains(event.kind) else { return .muted }
        guard rule.enabled else { return .ruleDisabled }
        guard rule.eventKind == event.kind else { return .eventKind }
        guard rule.repoScope.contains(repo) else { return .repoScope }
        if let failed = rule.conditions.first(where: { !satisfies($0, event) }) { return .condition(failed) }
        if let winner = candidates(for: event, in: repo, rules: config.rules).first, winner.id != rule.id {
            return .outranked(by: winner)
        }
        return nil
    }

    public static func overview(repo: Repository, kind: EventKind, config: Config) -> OverviewCell {
        guard repo.monitoring else { return .repoOff }
        guard !repo.mutedEventKinds.contains(kind) else { return .muted }
        let rules = ranked(config.rules.filter { $0.enabled && $0.eventKind == kind && $0.repoScope.contains(repo) })
        guard let first = rules.first else { return .none }
        if first.conditions.isEmpty { return .rule(first) }
        let end = rules.firstIndex { $0.conditions.isEmpty }.map { $0 + 1 } ?? rules.count
        return .conditional(Array(rules[..<end]))
    }

    static func satisfies(_ conditions: [Condition], _ event: Event) -> Bool {
        conditions.allSatisfy { satisfies($0, event) }
    }

    static func satisfies(_ condition: Condition, _ event: Event) -> Bool {
        let pr = event.subject.pullRequest
        let labels = Set((pr?.labels ?? []).map { $0.lowercased() })
        switch condition {
        case .actorKind(let kind):
            // Events without an actor (review requests, dry runs) cannot be judged, so they pass.
            guard let actor = event.actor else { return true }
            switch kind {
            case .any: return true
            case .bot: return actor.isBot
            case .human: return !actor.isBot
            }
        case .includeDraft(let include): return include || pr?.isDraft != true
        case .labelsInclude(let required): return required.isEmpty || required.contains { labels.contains($0.lowercased()) }
        case .labelsExclude(let excluded): return !excluded.contains { labels.contains($0.lowercased()) }
        }
    }

    static func ranked(_ rules: [Rule]) -> [Rule] {
        rules.enumerated().sorted { ($0.element.priority, -$0.offset) > ($1.element.priority, -$1.offset) }.map(\.element)
    }
}
