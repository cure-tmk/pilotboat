import Foundation

/// Pure decisions of the run pipeline. `Engine` reads and writes state around them and emits the notices.
enum RunPolicy {
    struct DispatchPlan {
        /// Every run whose state changed, in candidate order.
        var updates: [Run] = []
        /// Runs moved to `.launching`; the engine starts a launch for each.
        var started: [Run] = []
        var notices: [EngineEvent] = []
    }

    /// Renders the snapshot of a run whose settle window ended and decides where it goes next.
    /// `viaApproval` is false for trial runs, which bypass a disabled rule and the approval step.
    static func settle(run: Run, events: [Event], config: Config, now: Date, viaApproval: Bool,
                       describeError: (any Error) -> String) -> (Run, EngineEvent) {
        var run = run
        run.updatedAt = now
        guard let rule = config.rule(id: run.ruleId), rule.enabled || !viaApproval else {
            run.state = .skipped
            run.skipReason = .ruleRemoved
            return (run, .runsChanged)
        }
        guard let latest = events.max(by: { $0.occurredAt < $1.occurredAt }), let template = config.promptTemplate(id: rule.promptTemplateId) else {
            run.state = .failed
            run.error = describeError(EngineError.templateNotFound(rule.promptTemplateId))
            return (run, .runFailed(run))
        }
        run.snapshot = RunSnapshot(launcherId: rule.launcherId, workspacePolicy: rule.workspacePolicy,
                                   renderedPrompt: PromptRenderer.render(template: template.body, events: events),
                                   subject: latest.subject)
        if latest.subject.pullRequest?.isCrossRepository == true {
            run.state = .skipped
            run.skipReason = .crossRepository
            return (run, .runsChanged)
        }
        if viaApproval && rule.executionMode == .confirm {
            run.state = .pendingApproval
            return (run, .runNeedsApproval(run))
        }
        run.state = .queued
        return (run, .runsChanged)
    }

    /// `candidates` are queued and held runs; held runs wait until the day after they were held.
    static func planDispatch(candidates: [Run], launching: [Run], launchedToday: Int, general: GeneralSettings, now: Date) -> DispatchPlan {
        let today = Calendar.current.startOfDay(for: now)
        var launching = launching
        var plan = DispatchPlan()
        for var run in candidates.filter({ $0.state == .queued || $0.updatedAt < today }).sorted(by: { $0.createdAt < $1.createdAt }) {
            guard launching.count < general.maxConcurrentLaunches else { break }
            guard !launching.contains(where: { $0.repo == run.repo && $0.prNumber == run.prNumber }) else { continue }
            run.updatedAt = now
            if launchedToday >= general.dailyLaunchLimit {
                run.state = .held
                plan.notices.append(.runHeld(run))
            } else if launchedToday + launching.count >= general.dailyLaunchLimit {
                // In-flight launches may still fail; each completion dispatches again.
                break
            } else {
                run.state = .launching
                launching.append(run)
                plan.started.append(run)
                plan.notices.append(.runsChanged)
            }
            plan.updates.append(run)
        }
        return plan
    }

    /// Event kinds of `repo` whose baseline moves to now when `old` becomes `new`, so events from before the change do not fire.
    static func baselineKinds(old: Config, new: Config, repo: Repository, resumed: Bool) -> Set<EventKind> {
        guard let previous = old.repository(id: repo.id), previous.monitoring || !repo.monitoring else { return EventKind.supported }
        var kinds = resumed ? EventKind.supported : coveredKinds(new).subtracting(coveredKinds(old))
        if !old.general.includeTeamReviewRequests && new.general.includeTeamReviewRequests { kinds.insert(.reviewRequested) }
        return kinds.union(previous.mutedEventKinds.subtracting(repo.mutedEventKinds))
    }

    static func coveredKinds(_ config: Config) -> Set<EventKind> {
        Set(config.rules.filter(\.enabled).map(\.eventKind))
    }

    // ponytail: runs are matched to repositories by fullName only; add the host to Run if several hosts share names.
    static func outOfScope(_ run: Run, _ config: Config) -> SkipReason? {
        guard let rule = config.rule(id: run.ruleId), rule.enabled else { return .ruleRemoved }
        guard config.general.monitoring,
              let repo = config.repositories.first(where: { $0.fullName == run.repo }),
              repo.monitoring, !repo.mutedEventKinds.contains(rule.eventKind) else { return .monitoringOff }
        return nil
    }

    static func monitoring(_ general: GeneralSettings) -> EngineStatus.Monitoring {
        if general.monitoring { return .on }
        return general.monitoringOffUntil.map { .offUntil($0) } ?? .off
    }
}
