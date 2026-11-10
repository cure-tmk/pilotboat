import Foundation
import Testing
@testable import Core

@Suite struct BaselineAndDedupeTests {
    @Test func firstLaunchIgnoresExistingReviewRequests() async throws {
        let h = try Harness()
        let pr = makePR()
        h.source.events = [reviewRequested(pr, at: startDate - 3600)]
        await h.tick()
        #expect(h.launcher.requests.isEmpty)

        h.clock.advance(60)
        h.source.events.append(reviewRequested(makePR(number: 2), at: h.clock.now))
        await h.tick()
        #expect(h.launcher.requests.map(\.subject.pullRequest?.number) == [2])
    }

    @Test func firstLaunchCanIncludeExistingReviewRequests() async throws {
        let h = try Harness()
        try await h.engine.completeFirstLaunch(includeExistingReviewRequests: true)
        h.source.events = [
            reviewRequested(makePR(number: 1), at: startDate - 3600),
            reviewSubmitted(makePR(number: 2), id: 1, at: startDate - 3600),
        ]
        await h.tick()
        h.clock.advance(200)
        await h.tick()
        #expect(h.launcher.requests.map(\.subject.pullRequest?.number) == [1])
    }

    @Test(arguments: [false, true])
    func completeFirstLaunchOverridesBaselinesFromSetup(includeExisting: Bool) async throws {
        let h = try Harness { $0.repositories = [] }
        h.clock.advance(60)
        try await h.engine.updateConfig { $0.repositories = [apiRepo] }
        h.source.events = [reviewRequested(makePR(number: 1), at: startDate - 3600)]
        try await h.engine.completeFirstLaunch(includeExistingReviewRequests: includeExisting)
        await h.tick()
        #expect(h.launcher.requests.map(\.subject.pullRequest?.number) == (includeExisting ? [1] : []))
    }

    @Test func tickBeforeCompleteFirstLaunchDoesNotBlockIncludedRequests() async throws {
        let h = try Harness()
        h.source.events = [reviewRequested(makePR(number: 1), at: startDate - 3600)]
        await h.tick()
        #expect(h.launcher.requests.isEmpty)
        h.clock.advance(60)
        try await h.engine.completeFirstLaunch(includeExistingReviewRequests: true)
        h.source.events = [reviewRequested(makePR(number: 2), at: startDate - 1800)]
        await h.tick()
        #expect(h.launcher.requests.map(\.subject.pullRequest?.number) == [2])
    }

    @Test(arguments: [false, true])
    func resumingAfterOffOverridesEarlierBaseline(includeExisting: Bool) async throws {
        let h = try Harness()
        await h.tick()
        try await h.engine.setMonitoring(false)
        h.clock.advance(60)
        h.source.events = [reviewRequested(makePR(number: 1), at: h.clock.now)]
        h.clock.advance(60)
        try await h.engine.setMonitoring(true, includeExistingReviewRequests: includeExisting)
        await h.tick()
        #expect(h.launcher.requests.map(\.subject.pullRequest?.number) == (includeExisting ? [1] : []))
    }

    @Test func sameEventLaunchesOnceAcrossTicksAndRestarts() async throws {
        let h = try Harness()
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(), at: h.clock.now)]
        await h.tick()
        await h.tick()
        let restarted = try h.restartedEngine()
        _ = await restarted.tick()
        await restarted.waitForLaunches()
        #expect(h.launcher.requests.count == 1)
        #expect(h.source.pollCount == 4)
    }

    @Test(arguments: [false, true])
    func resumingMonitoringCarriesOverOnlyWhenAsked(includeExisting: Bool) async throws {
        let h = try Harness()
        await h.tick()
        try await h.engine.setMonitoring(false)
        h.clock.advance(60)
        h.source.events = [reviewRequested(makePR(number: 1), at: h.clock.now), reviewSubmitted(makePR(number: 2), id: 1, at: h.clock.now)]
        #expect(await h.tick() == .monitoringOff(until: nil))
        #expect(h.source.pollCount == 1)

        h.clock.advance(60)
        try await h.engine.setMonitoring(true, includeExistingReviewRequests: includeExisting)
        await h.tick()
        h.clock.advance(200)
        await h.tick()
        #expect(h.launcher.requests.map(\.subject.pullRequest?.number) == (includeExisting ? [1] : []))
    }

    @Test func reEnablingRepoOrUnmutingSetsBaseline() async throws {
        let h = try Harness()
        await h.tick()
        try await h.engine.updateConfig {
            $0.repositories[0].monitoring = false
            $0.repositories[1].mutedEventKinds = [.reviewRequested]
        }
        h.clock.advance(60)
        h.source.events = [reviewRequested(makePR(repo: "o/api"), at: h.clock.now), reviewRequested(makePR(repo: "o/web"), at: h.clock.now)]
        await h.tick()
        h.clock.advance(60)
        try await h.engine.updateConfig {
            $0.repositories[0].monitoring = true
            $0.repositories[1].mutedEventKinds = []
        }
        await h.tick()
        #expect(h.launcher.requests.isEmpty)
    }

    @Test func enablingRuleDoesNotFireForPastEvents() async throws {
        let h = try Harness { $0.rules[0].enabled = false }
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(number: 1), at: h.clock.now)]
        await h.tick()
        h.clock.advance(10)
        let unseen = reviewRequested(makePR(number: 2), at: h.clock.now)
        h.clock.advance(10)
        try await h.engine.updateConfig { $0.rules[0].enabled = true }
        h.clock.advance(10)
        h.source.events += [unseen, reviewRequested(makePR(number: 3), at: h.clock.now)]
        await h.tick()
        #expect(h.launcher.requests.map(\.subject.pullRequest?.number) == [3])
    }

    @Test func includingTeamRequestsDoesNotFireForPastRequests() async throws {
        let h = try Harness()
        await h.tick()
        h.clock.advance(10)
        let teamRequest = reviewRequested(makePR(number: 1), at: h.clock.now)
        h.clock.advance(10)
        try await h.engine.updateConfig { $0.general.includeTeamReviewRequests = true }
        h.clock.advance(10)
        h.source.events = [teamRequest, reviewRequested(makePR(number: 2), at: h.clock.now)]
        await h.tick()
        #expect(h.launcher.requests.map(\.subject.pullRequest?.number) == [2])
    }

    @Test func failedStateWriteLeavesConfigUnchanged() async throws {
        let store = FailingStateStore()
        let configStore = InMemoryConfigStore(baseConfig())
        let engine = try Engine(configStore: configStore, stateStore: store, sources: [:], launchers: [:], time: FakeClock(startDate))
        store.failWrites = true
        await #expect(throws: FakeError.self) { try await engine.updateConfig { $0.rules[0].enabled = false } }
        #expect(await engine.config == baseConfig())
        #expect(try configStore.load() == baseConfig())
    }

    @Test func processedEventsArePurgedOnceADay() async throws {
        let h = try Harness()
        let event = reviewRequested(makePR(), at: startDate)
        h.source.events = [event]
        await h.tick()
        h.source.events = []
        h.clock.advance(Engine.processedRetention + 1)
        await h.tick()
        #expect(try h.store.read { try !$0.hasProcessed(dedupeKey: event.dedupeKey) })
        try h.store.write { try $0.markProcessed(event, seenAt: startDate) }
        await h.tick()
        #expect(try h.store.read { try $0.hasProcessed(dedupeKey: event.dedupeKey) })
    }

    @Test func newRepositoryGetsBaseline() async throws {
        let h = try Harness()
        await h.tick()
        h.clock.advance(60)
        let pr = makePR(repo: "o/new")
        h.source.events = [reviewRequested(pr, at: h.clock.now)]
        h.clock.advance(60)
        try await h.engine.updateConfig { $0.repositories.append(Repository(fullName: "o/new")) }
        await h.tick()
        #expect(h.launcher.requests.isEmpty)
    }
}

@Suite struct MatchingTests {
    @Test func repoSpecificRuleOverridesCommonRule() async throws {
        let h = try Harness {
            $0.promptTemplates.append(PromptTemplate(id: "api", name: "api", body: "API {{pr.url}}"))
            $0.rules.append(Rule(id: "api", name: "api", enabled: true, priority: 10, eventKind: .reviewRequested, repoScope: .only([apiRepo.id]),
                                 settleSeconds: 0, launcherId: "main", workspacePolicy: .alwaysNew, promptTemplateId: "api", executionMode: .auto))
        }
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(repo: "o/api"), at: h.clock.now), reviewRequested(makePR(repo: "o/web"), at: h.clock.now)]
        await h.tick()
        let prompts = Dictionary(uniqueKeysWithValues: h.launcher.requests.map { ($0.repository.fullName, $0.prompt) })
        #expect(prompts["o/api"] == "API https://github.com/o/api/pull/1")
        #expect(prompts["o/web"] == "Review https://github.com/o/web/pull/1")
    }

    @Test func mutedKindDoesNotLaunchAndShowsInOverview() async throws {
        let h = try Harness { $0.repositories[0].mutedEventKinds = [.reviewRequested] }
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(repo: "o/api"), at: h.clock.now)]
        await h.tick()
        #expect(h.launcher.requests.isEmpty)
        let config = await h.engine.config
        #expect(await h.engine.overview(repo: config.repositories[0], kind: .reviewRequested) == .muted)
        #expect(await h.engine.overview(repo: config.repositories[1], kind: .reviewRequested) == .rule(config.rules[0]))
        #expect(await h.engine.overview(repo: config.repositories[1], kind: .reviewSubmitted) == .conditional([config.rules[1]]))
    }

    @Test func equalPriorityPrefersEarlierRuleAndConditionsFilter() {
        var config = baseConfig()
        config.rules.append(Rule(id: "late", name: "late", enabled: true, priority: 0, eventKind: .reviewRequested, settleSeconds: 0,
                                 launcherId: "main", workspacePolicy: .alwaysNew, promptTemplateId: "rr"))
        config.rules.append(Rule(id: "drafts", name: "drafts", enabled: true, priority: 5, eventKind: .reviewRequested,
                                 conditions: [.includeDraft(false), .labelsExclude(["WIP"])], settleSeconds: 0,
                                 launcherId: "main", workspacePolicy: .alwaysNew, promptTemplateId: "rr"))
        let plain = reviewRequested(makePR(), at: startDate)
        let draft = reviewRequested(makePR(draft: true), at: startDate)
        let wip = reviewRequested(makePR(labels: ["wip"]), at: startDate)
        #expect(RuleMatcher.match(plain, in: apiRepo, config: config) == .matched(config.rule(id: "drafts")!))
        #expect(RuleMatcher.match(draft, in: apiRepo, config: config) == .matched(config.rule(id: "rr")!))
        #expect(RuleMatcher.match(wip, in: apiRepo, config: config) == .matched(config.rule(id: "rr")!))
        let bot = reviewSubmitted(makePR(), id: 1, at: startDate, bot: true)
        #expect(RuleMatcher.match(bot, in: apiRepo, config: config) == .noRule)
    }
}

@Suite struct SettleTests {
    @Test func threeReviewsMergeIntoOneRun() async throws {
        let h = try Harness()
        await h.tick()
        let pr = makePR()
        for id in 1...3 {
            h.clock.advance(30)
            h.source.events.append(reviewSubmitted(pr, id: id, at: h.clock.now, by: "r\(id)", state: id == 3 ? "APPROVED" : "COMMENTED"))
            await h.tick()
        }
        h.clock.advance(100)
        await h.tick()
        #expect(h.launcher.requests.isEmpty)
        h.clock.advance(20)
        await h.tick()
        #expect(h.launcher.requests.map(\.prompt) == ["Reply r3 APPROVED x3"])
        let run = try #require(try await h.runs().first)
        #expect(try await h.engine.eventsForRun(id: run.id).count == 3)
    }

    @Test func settleExtensionIsCappedAtTenMinutes() async throws {
        let h = try Harness()
        await h.tick()
        let pr = makePR()
        let created = h.clock.now + 60
        for id in 1...6 {
            h.clock.advance(60 + (id == 1 ? 0 : 40))
            h.source.events.append(reviewSubmitted(pr, id: id, at: h.clock.now))
            await h.tick()
        }
        let run = try #require(try await h.runs().first)
        #expect(run.state == .settling)
        #expect(run.settleUntil == created + 600)
        h.clock.advance((created + 600).timeIntervalSince(h.clock.now))
        await h.tick()
        #expect(h.launcher.requests.count == 1)
    }
}

@Suite struct ApprovalTests {
    func confirmHarness() throws -> Harness {
        try Harness { $0.rules[0].executionMode = .confirm }
    }

    @Test func confirmWaitsForApproval() async throws {
        let h = try confirmHarness()
        await h.tick()
        h.clock.advance(10)
        let pr = makePR()
        h.source.events = [reviewRequested(pr, at: h.clock.now)]
        h.source.openReviewRequests = [pr]
        var stream = h.engine.events.makeAsyncIterator()
        await h.tick()
        #expect(h.launcher.requests.isEmpty)
        let pending = try #require(try await h.engine.pendingApprovalRuns().first)
        #expect(pending.snapshot?.renderedPrompt == "Review https://github.com/o/api/pull/1")
        var sawApproval = false
        while let event = await stream.next() {
            if case .runNeedsApproval(let run) = event { sawApproval = run.id == pending.id; break }
        }
        #expect(sawApproval)

        try await h.engine.approve(runId: pending.id)
        await h.engine.waitForLaunches()
        #expect(try await h.engine.run(id: pending.id)?.state == .launched)
    }

    @Test func approvalTimesOutAfter24Hours() async throws {
        let h = try confirmHarness()
        await h.tick()
        h.clock.advance(10)
        let pr = makePR()
        h.source.events = [reviewRequested(pr, at: h.clock.now)]
        h.source.openReviewRequests = [pr]
        await h.tick()
        h.clock.advance(86_399)
        await h.tick()
        #expect(try await h.engine.pendingApprovalRuns().count == 1)
        h.clock.advance(1)
        await h.tick()
        let run = try #require(try await h.runs().first)
        #expect(run.state == .skipped && run.skipReason == .approvalTimeout)
    }

    @Test(arguments: [(EventKind.reviewRequested, PullRequestState.closed), (.reviewSubmitted, .merged)])
    func closedPullRequestSkipsPendingRun(kind: EventKind, state: PullRequestState) async throws {
        let h = try Harness {
            $0.rules[0].executionMode = .confirm
            $0.rules[1].executionMode = .confirm
        }
        await h.tick()
        h.clock.advance(10)
        let pr = makePR()
        h.source.events = [kind == .reviewRequested ? reviewRequested(pr, at: h.clock.now) : reviewSubmitted(pr, id: 1, at: h.clock.now)]
        await h.tick()
        h.clock.advance(120)
        await h.tick()
        #expect(try await h.engine.pendingApprovalRuns().count == 1)

        h.source.pullRequestStates = [pr.number: state]
        h.source.pullRequestError = FakeError(description: "offline")
        for _ in 0..<Engine.pullRequestCheckEveryTicks { await h.tick() }
        #expect(try await h.engine.pendingApprovalRuns().count == 1)

        h.source.pullRequestError = nil
        for _ in 0..<Engine.pullRequestCheckEveryTicks { await h.tick() }
        let run = try #require(try await h.runs().first)
        #expect(run.state == .skipped && run.skipReason == .prClosed)
    }

    @Test func pendingPullRequestIsCheckedEveryFewTicks() async throws {
        let h = try confirmHarness()
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(), at: h.clock.now)]
        await h.tick()
        for _ in 0..<(2 * Engine.pullRequestCheckEveryTicks) { await h.tick() }
        #expect(h.source.pullRequestCount == 2)
    }

    @Test func monitoringOffAndRuleDisableSkipUnfinishedRuns() async throws {
        let h = try Harness {
            $0.rules[0].executionMode = .confirm
            $0.rules[1].executionMode = .confirm
        }
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(number: 1), at: h.clock.now), reviewSubmitted(makePR(number: 2), id: 1, at: h.clock.now)]
        h.source.openReviewRequests = [makePR(number: 1)]
        await h.tick()
        try await h.engine.updateConfig { $0.rules[1].enabled = false }
        try await h.engine.setMonitoring(false)
        let reasons = try await h.runs().map { "\($0.prNumber):\($0.state.rawValue):\($0.skipReason?.rawValue ?? "")" }.sorted()
        #expect(reasons == ["1:skipped:monitoringOff", "2:skipped:ruleRemoved"])
    }

    @Test func timedPauseResumesWithoutCarryOver() async throws {
        let h = try Harness()
        await h.tick()
        let until = h.clock.now + 1800
        try await h.engine.pauseMonitoring(until: until)
        #expect(await h.engine.status.monitoring == .offUntil(until))
        h.clock.advance(60)
        h.source.events = [reviewRequested(makePR(), at: h.clock.now)]
        #expect(await h.tick() == .monitoringOff(until: until))
        h.clock.advance(1800)
        #expect(await h.tick() == .completed)
        #expect(await h.engine.config.general.monitoring)
        #expect(h.launcher.requests.isEmpty)
    }
}

@Suite struct QueueTests {
    func queue(_ h: Harness, prs: [PullRequestRef]) async {
        await h.tick()
        h.clock.advance(10)
        h.source.events = prs.map { reviewRequested($0, at: h.clock.now) }
        await h.tick()
    }

    @Test func dailyLimitHoldsUntilNextDay() async throws {
        let h = try Harness { $0.general.dailyLaunchLimit = 2 }
        await queue(h, prs: (1...3).map { makePR(number: $0) })
        #expect(h.launcher.requests.count == 2)
        #expect(try await h.runs().filter { $0.state == .held }.count == 1)
        h.clock.advance(3600)
        await h.tick()
        #expect(h.launcher.requests.count == 2)
        h.clock.advance(86_400)
        await h.tick()
        #expect(h.launcher.requests.count == 3)
    }

    @Test func inFlightLaunchesDoNotHoldAgainstDailyLimit() async throws {
        let h = try Harness { $0.general.dailyLaunchLimit = 2 }
        await queue(h, prs: [makePR(number: 1)])
        h.launcher.hold()
        h.clock.advance(10)
        h.source.events += [reviewRequested(makePR(number: 2), at: h.clock.now), reviewRequested(makePR(number: 3), at: h.clock.now)]
        _ = await h.engine.tick()
        let states = try await h.runs().map(\.state.rawValue).sorted()
        #expect(states == ["launched", "launching", "queued"])

        h.launcher.failNext("boom")
        h.launcher.release()
        await h.engine.waitForLaunches()
        #expect(try await h.runs().map(\.state.rawValue).sorted() == ["failed", "launched", "launched"])
        #expect(h.launcher.requests.count == 3)
    }

    @Test func maxConcurrentLaunchesIsRespected() async throws {
        let launcher = FakeLauncher()
        launcher.hold()
        let h = try Harness(launcher: launcher) { $0.general.maxConcurrentLaunches = 2 }
        await h.tick()
        h.clock.advance(10)
        h.source.events = (1...3).map { reviewRequested(makePR(number: $0), at: h.clock.now) }
        _ = await h.engine.tick()
        let states = try await h.runs().map { "\($0.prNumber):\($0.state.rawValue)" }.sorted()
        #expect(states == ["1:launching", "2:launching", "3:queued"])
        launcher.release()
        await h.engine.waitForLaunches()
        #expect(try await h.runs().allSatisfy { $0.state == .launched })
    }

    @Test func onlyOneLaunchPerPullRequestAtATime() async throws {
        let launcher = FakeLauncher()
        launcher.hold()
        let h = try Harness(launcher: launcher)
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(), at: h.clock.now)]
        _ = await h.engine.tick()
        let trial = try await h.engine.trialRun(ruleId: "rr", prURL: makePR().url)
        #expect(trial.state == .queued)
        launcher.release()
        await h.engine.waitForLaunches()
        #expect(try await h.runs().allSatisfy { $0.state == .launched })
        #expect(h.launcher.requests.count == 2)
    }

    @Test func crossRepositoryPullRequestIsSkipped() async throws {
        let h = try Harness()
        await queue(h, prs: [makePR(crossRepository: true)])
        let run = try #require(try await h.runs().first)
        #expect(run.state == .skipped && run.skipReason == .crossRepository)
        #expect(h.launcher.requests.isEmpty)
    }

    @Test func failedLaunchCanBeRetried() async throws {
        let h = try Harness()
        h.launcher.failNext("orca not found")
        await queue(h, prs: [makePR()])
        let failed = try #require(try await h.runs().first)
        #expect(failed.state == .failed && failed.error == "orca not found")
        try await h.engine.retry(runId: failed.id)
        await h.engine.waitForLaunches()
        let launched = try #require(try await h.engine.run(id: failed.id))
        #expect(launched.state == .launched && launched.error == nil)
        #expect(h.launcher.requests.map(\.runId) == [failed.id, failed.id])
    }

    @Test func dispatchWriteFailureFailsTheTick() async throws {
        let h = try Harness()
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(), at: h.clock.now)]
        h.store.writesBeforeFailure = 2
        #expect(await h.tick() == .failed(consecutiveFailures: 1))
        #expect(await h.engine.status.lastError == "disk full")
        #expect(h.launcher.requests.isEmpty)
    }

    @Test func dispatchFailureOutsideTickIsReported() async throws {
        let h = try Harness { $0.rules[0].executionMode = .confirm }
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(), at: h.clock.now)]
        await h.tick()
        let pending = try #require(try await h.engine.pendingApprovalRuns().first)
        h.store.writesBeforeFailure = 1
        try await h.engine.approve(runId: pending.id)
        #expect(await h.engine.status.lastError == "disk full")
        #expect(h.launcher.requests.isEmpty)
    }

    @Test func launchWriteFailureIsReported() async throws {
        let h = try Harness()
        h.launcher.hold()
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(), at: h.clock.now)]
        _ = await h.engine.tick()
        var stream = h.engine.events.makeAsyncIterator()
        h.store.failWrites = true
        h.launcher.release()
        await h.engine.waitForLaunches()
        #expect(await h.engine.status.lastError == "disk full")
        var reported = false
        while let event = await stream.next() {
            if case .statusChanged(let status) = event, status.lastError == "disk full" { reported = true; break }
        }
        #expect(reported)
    }

    @Test func launchErrorUsesLocalizedDescription() async throws {
        let h = try Harness()
        h.launcher.failNext(with: FakeLocalizedError.broken)
        await queue(h, prs: [makePR()])
        #expect(try await h.runs().first?.error == "Readable message")
    }

    @Test func retryableFailureKeepsTokenForRetry() async throws {
        let h = try Harness { $0.launchers[0].settings = .object(["x": .string("y")]) }
        h.launcher.failNext("lost", retryToken: "launch:op_9")
        await queue(h, prs: [makePR()])
        let failed = try #require(try await h.runs().first)
        #expect(failed.state == .failed && failed.retryToken == "launch:op_9")
        try await h.engine.retry(runId: failed.id)
        await h.engine.waitForLaunches()
        #expect(h.launcher.requests.map(\.retryToken) == [nil, "launch:op_9"])
        let launched = try #require(try await h.engine.run(id: failed.id))
        #expect(launched.state == .launched && launched.retryToken == nil)
        try await h.engine.openWorkspace(runId: failed.id)
        #expect(h.launcher.opened.map(\.0) == [launched.workspaceRef!] && h.launcher.opened.map(\.1) == [.object(["x": .string("y")])])
    }

    @Test func leftoverLaunchingRunsFailOnStartup() async throws {
        let h = try Harness()
        try h.store.write { try $0.insertRun(Run(state: .launching, ruleId: "rr", repo: "o/api", prNumber: 1, createdAt: startDate, updatedAt: startDate)) }
        _ = try h.restartedEngine()
        #expect(try await h.runs().first?.state == .failed)
    }

    @Test(arguments: [false, true])
    func workspacePolicyFollowsLauncherCapabilities(canReuse: Bool) async throws {
        let h = try Harness(launcher: FakeLauncher(capabilities: canReuse ? [.reuseWorkspace] : [])) { $0.rules[0].workspacePolicy = .reusePrevious }
        await h.tick()
        h.clock.advance(10)
        h.source.events = [reviewRequested(makePR(number: 1), at: h.clock.now), reviewSubmitted(makePR(number: 2), id: 1, at: h.clock.now)]
        await h.tick()
        h.clock.advance(120)
        await h.tick()
        let policies = h.launcher.requests.sorted { $0.subject.pullRequest!.number < $1.subject.pullRequest!.number }.map(\.workspacePolicy)
        #expect(policies == (canReuse ? [.reusePrevious, .reuseOrCreate] : [.alwaysNew, .alwaysNew]))
    }

    @Test func reuseFallsBackToAlwaysNewAndPassesPreviousWorkspace() async throws {
        let h = try Harness(launcher: FakeLauncher(capabilities: [])) { $0.rules[0].workspacePolicy = .reusePrevious }
        await h.tick()
        let pr = makePR()
        h.clock.advance(10)
        h.source.events = [reviewRequested(pr, at: h.clock.now), reviewSubmitted(pr, id: 1, at: h.clock.now)]
        await h.tick()
        h.clock.advance(120)
        await h.tick()
        let requests = h.launcher.requests
        #expect(requests.map(\.workspacePolicy) == [.alwaysNew, .alwaysNew])
        #expect(requests[0].previousWorkspaceRef == nil)
        #expect(requests[1].previousWorkspaceRef == "ws-\(requests[0].runId)")
    }
}

@Suite struct PreviewTests {
    let url = URL(string: "https://github.com/o/web/pull/7")!

    @Test func dryRunReportsOutrankingRuleWithoutRecording() async throws {
        let h = try Harness {
            $0.rules.append(Rule(id: "web", name: "web", enabled: true, priority: 3, eventKind: .reviewRequested, repoScope: .only([webRepo.id]),
                                 settleSeconds: 0, launcherId: "main", workspacePolicy: .alwaysNew, promptTemplateId: "rr"))
        }
        let report = try await h.engine.dryRun(ruleId: "rr", prURL: url)
        #expect(report.mismatch == .outranked(by: await h.engine.config.rule(id: "web")!))
        #expect(report.winningRule?.id == "web")
        #expect(report.renderedPrompt == "Review https://github.com/o/web/pull/7")
        #expect(report.launcherDescription == "fake launch https://github.com/o/web/pull/7 alwaysNew")
        #expect(try await h.runs().isEmpty)
    }

    @Test func trialRunBypassesBaselineAndApproval() async throws {
        let h = try Harness { $0.rules[0].executionMode = .confirm; $0.rules[0].enabled = false }
        await h.tick()
        let run = try await h.engine.trialRun(ruleId: "rr", prURL: url)
        await h.engine.waitForLaunches()
        #expect(try await h.engine.run(id: run.id)?.state == .launched)
        #expect(try await h.engine.eventsForRun(id: run.id).first?.dedupeKey.hasPrefix("trial:") == true)
        #expect(try await h.engine.renderPreview(templateId: "rr", prURL: url) == "Review https://github.com/o/web/pull/7")
    }

    @Test func diagnosticsAggregateSourcesAndLaunchers() async throws {
        let h = try Harness()
        #expect(await h.engine.diagnostics().map(\.title) == ["source", "main: launcher"])
    }
}

@Suite struct SchedulerTests {
    @Test func backsOffOnFailuresAndUsesIntervalOtherwise() async throws {
        let h = try Harness()
        h.source.error = FakeError(description: "offline")
        let (delays, continuation) = AsyncStream.makeStream(of: Duration.self)
        let scheduler = Scheduler(engine: h.engine, time: h.clock) { delay in
            continuation.yield(delay)
            try await Task.sleep(for: .seconds(3600))
        }
        await scheduler.start()
        var iterator = delays.makeAsyncIterator()
        var observed: [Duration] = []
        for _ in 0..<3 {
            observed.append(await iterator.next()!)
            await scheduler.triggerNow()
        }
        h.source.error = nil
        observed.append(await iterator.next()!)
        await scheduler.stop()
        #expect(observed == [.seconds(60), .seconds(120), .seconds(240), .seconds(120)])
        #expect(await h.engine.status.lastError == nil)
    }
}
