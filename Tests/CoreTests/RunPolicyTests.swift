import Foundation
import Testing
@testable import Core

@Suite struct PlanDispatchTests {
    let yesterday = startDate - 86_400

    func run(_ n: Int, _ state: RunState = .queued, created: TimeInterval = 0, updated: Date? = nil) -> Run {
        Run(state: state, ruleId: "rr", repo: "o/api", prNumber: n, createdAt: startDate + created, updatedAt: updated ?? startDate + created)
    }

    func general(max: Int = 3, limit: Int = 20) -> GeneralSettings {
        var g = GeneralSettings()
        g.maxConcurrentLaunches = max
        g.dailyLaunchLimit = limit
        return g
    }

    func plan(_ candidates: [Run], launching: [Run] = [], launchedToday: Int = 0, _ general: GeneralSettings) -> RunPolicy.DispatchPlan {
        RunPolicy.planDispatch(candidates: candidates, launching: launching, launchedToday: launchedToday, general: general, now: startDate + 100)
    }

    func summary(_ p: RunPolicy.DispatchPlan) -> [String] { p.updates.map { "\($0.prNumber):\($0.state.rawValue)" } }

    @Test func dailyLimitReachedHoldsEveryCandidate() {
        let p = plan([run(1), run(2, created: 1)], launchedToday: 2, general(limit: 2))
        #expect(summary(p) == ["1:held", "2:held"])
        #expect(p.started.isEmpty && p.notices.count == 2)
    }

    @Test func inFlightLaunchesAtLimitStopDispatchingWithoutHolding() {
        let p = plan([run(2), run(3, created: 1)], launching: [run(1, .launching)], launchedToday: 1, general(limit: 2))
        #expect(p.updates.isEmpty && p.started.isEmpty && p.notices.isEmpty)
    }

    @Test func heldRunsWaitUntilTheNextDay() {
        let p = plan([run(1, .held, updated: startDate), run(2, .held, created: 1, updated: yesterday)], general())
        #expect(summary(p) == ["2:launching"])
    }

    @Test func maxConcurrentLaunchesStartsOldestFirst() {
        let p = plan([run(3, created: 2), run(1), run(2, created: 1)], launching: [run(9, .launching)], general(max: 3))
        #expect(p.started.map(\.prNumber) == [1, 2])
        #expect(p.started.allSatisfy { $0.updatedAt == startDate + 100 })
    }

    @Test func onePullRequestLaunchesAtATimeAndOthersStillStart() {
        let p = plan([run(1), run(1, created: 1), run(2, created: 2)], launching: [], general())
        #expect(summary(p) == ["1:launching", "2:launching"])
    }
}

@Suite struct SettlePolicyTests {
    func settle(_ pr: PullRequestRef = makePR(), viaApproval: Bool = true, _ configure: (inout Config) -> Void = { _ in }) -> (Run, EngineEvent) {
        var config = baseConfig()
        configure(&config)
        let run = Run(state: .settling, ruleId: "rr", repo: pr.repo, prNumber: pr.number, createdAt: startDate, updatedAt: startDate)
        return RunPolicy.settle(run: run, events: [reviewRequested(pr, at: startDate)], config: config, now: startDate + 5,
                                viaApproval: viaApproval, describeError: { "described \($0)" })
    }

    @Test func autoRuleQueuesWithSnapshot() {
        let (run, _) = settle()
        #expect(run.state == .queued && run.updatedAt == startDate + 5)
        #expect(run.snapshot?.renderedPrompt == "Review https://github.com/o/api/pull/1")
    }

    @Test func crossRepositoryIsSkipped() {
        let (run, _) = settle(makePR(crossRepository: true))
        #expect(run.state == .skipped && run.skipReason == .crossRepository)
    }

    @Test func confirmNeedsApprovalUnlessTrial() {
        let (run, event) = settle { $0.rules[0].executionMode = .confirm }
        #expect(run.state == .pendingApproval)
        if case .runNeedsApproval(let r) = event { #expect(r == run) } else { Issue.record("expected runNeedsApproval") }
        #expect(settle(viaApproval: false) { $0.rules[0].executionMode = .confirm; $0.rules[0].enabled = false }.0.state == .queued)
    }

    @Test func disabledRuleIsSkippedAndMissingTemplateFails() {
        #expect(settle { $0.rules[0].enabled = false }.0.skipReason == .ruleRemoved)
        let (run, _) = settle { $0.promptTemplates.removeAll { $0.id == "rr" } }
        #expect(run.state == .failed && run.error == "described \(EngineError.templateNotFound("rr"))")
    }
}

@Suite struct BaselineKindsTests {
    let repo = apiRepo

    func kinds(resumed: Bool = false, _ change: (inout Config) -> Void, old configureOld: (inout Config) -> Void = { _ in }) -> Set<EventKind> {
        var old = baseConfig()
        configureOld(&old)
        var new = old
        change(&new)
        return RunPolicy.baselineKinds(old: old, new: new, repo: new.repository(id: repo.id) ?? repo, resumed: resumed)
    }

    @Test func noChangeMovesNothing() { #expect(kinds { _ in }.isEmpty) }

    @Test func newRepositoryGetsEveryKind() {
        #expect(kinds({ _ in }, old: { $0.repositories.removeAll { $0.id == apiRepo.id } }) == EventKind.supported)
    }

    @Test func reEnabledRepositoryGetsEveryKind() {
        #expect(kinds({ $0.repositories[0].monitoring = true }, old: { $0.repositories[0].monitoring = false }) == EventKind.supported)
    }

    @Test func resumeMovesEveryKind() {
        #expect(kinds(resumed: true, { $0.general.monitoring = true }, old: { $0.general.monitoring = false }) == EventKind.supported)
    }

    @Test func unmutedKindMoves() {
        #expect(kinds({ $0.repositories[0].mutedEventKinds = [] }, old: { $0.repositories[0].mutedEventKinds = [.reviewSubmitted] }) == [.reviewSubmitted])
    }

    @Test func newlyCoveredKindMoves() {
        #expect(kinds({ $0.rules[1].enabled = true }, old: { $0.rules[1].enabled = false }) == [.reviewSubmitted])
    }

    @Test func includingTeamRequestsMovesReviewRequested() {
        #expect(kinds { $0.general.includeTeamReviewRequests = true } == [.reviewRequested])
        #expect(kinds({ $0.general.includeTeamReviewRequests = false }, old: { $0.general.includeTeamReviewRequests = true }).isEmpty)
    }
}
