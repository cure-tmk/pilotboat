import Core
import Foundation
@testable import LauncherOrca
import LauncherScript
import Persistence
import ProcessKit
import SourceGitHub
import Testing
@testable import Pilotboat

private let now = Date(timeIntervalSince1970: 1_750_000_000)

private func run(_ n: Int, updated: Date) -> Run {
    Run(state: .launched, ruleId: "r", repo: "o/api", prNumber: n, createdAt: updated, updatedAt: updated)
}

private func review(_ login: String, at: Date) -> Event {
    let pr = PullRequestRef(host: "github.com", repo: "o/api", number: 1, url: URL(string: "https://github.com/o/api/pull/1")!,
                            title: "t", headRef: "h", headSHA: "s", baseRef: "main", isDraft: false, isCrossRepository: false,
                            labels: [], author: "me")
    return Event(kind: .reviewSubmitted, repo: "o/api", subject: .pullRequest(pr), actor: Actor(login: login, isBot: false),
                 occurredAt: at, dedupeKey: "\(login)-\(at.timeIntervalSince1970)")
}

@Suite struct ActivityGroupingTests {
    @Test func groupsNewestDayFirstWithTodayAndYesterday() {
        let calendar = Calendar.current
        let runs = [run(1, updated: now - 86_400), run(2, updated: now), run(3, updated: now - 3 * 86_400), run(4, updated: now - 60)]
        let days = runs.groupedByDay(calendar: calendar, now: now)
        #expect(days.map(\.day) == [0, 1, 3].map { calendar.startOfDay(for: now - Double($0) * 86_400) })
        #expect(days[0].title == String(localized: "Today", bundle: .resources))
        #expect(days[1].title == String(localized: "Yesterday", bundle: .resources))
        #expect(days[0].runs.map(\.prNumber) == [2, 4])
        #expect([Run]().groupedByDay(now: now).isEmpty)
    }
}

@Suite struct ReviewSummaryTests {
    @Test func countsReviewsAndKeepsFirstOrderOfReviewers() {
        let events = [review("alice", at: now), review("bob", at: now + 10), review("alice", at: now + 20)]
        #expect(events.reviewSummary == ReviewSummary(count: 3, reviewers: ["alice", "bob"], last: now + 20))
    }

    @Test func nilWithoutReviews() {
        #expect([Event]().reviewSummary == nil)
    }
}

@Suite struct RuleSummaryTests {
    @Test func describesTriggerScopeAndApproval() {
        var config = Config()
        let repo = Repository(fullName: "o/api")
        config.repositories = [repo]
        var rule = Rule(name: "x", priority: 0, eventKind: .reviewRequested, settleSeconds: 0, launcherId: "orca",
                        workspacePolicy: .alwaysNew, promptTemplateId: "t", executionMode: .confirm)
        let parts = { rule.summary(config: config).components(separatedBy: " · ") }
        #expect(parts() == [EventKind.reviewRequested.shortName, String(localized: "All repositories", bundle: .resources),
                            String(localized: "Ask first", bundle: .resources)])
        rule.repoScope = .only([repo.id])
        rule.executionMode = .auto
        #expect(parts()[1] == "o/api")
        #expect(parts()[2] == String(localized: "Run automatically", bundle: .resources))
        rule.repoScope = .only([repo.id, UUID()])
        #expect(parts()[1] == String(localized: "\(2) repositories", bundle: .resources))
    }
}

@Suite struct HealthReportTests {
    @Test func groupsByLauncherPrefixOnce() {
        let report = HealthReport.make(from: [
            DiagnosticItem(level: .ok, title: "GitHub (github.com)", detail: "Signed in as me"),
            DiagnosticItem(level: .ok, title: "orca: Orca is running"),
            DiagnosticItem(level: .warning, title: "script: Script launcher", detail: "missing"),
            DiagnosticItem(level: .ok, title: "orca: Agent: claude"),
        ], tools: [ToolCheck(name: "git", path: "/usr/bin/git", version: "git 2")], searchPath: ["/usr/bin"])
        #expect(report.groups.map(\.owner) == ["GitHub (github.com)", "orca", "script"])
        #expect(report.groups[1].items.map(\.title) == ["Orca is running", "Agent: claude"])
        #expect(report.groups[0].items.map(\.title) == ["GitHub (github.com)"])
        #expect(report.tool("git")?.isOK == true)
        #expect(report.searchPath == ["/usr/bin"])
    }

    @Test func toolLevels() {
        #expect(ToolCheck(name: "git").item.level == .error)
        #expect(ToolCheck(name: "git", path: "/g").item.level == .warning)
        #expect(ToolCheck(name: "git", path: "/g", version: "1").item.level == .ok)
    }
}

@Suite struct OrcaBindingTests {
    @Test func bindsUnboundRepositoriesByCanonicalKey() {
        let bound = Repository(fullName: "o/bound", launcherBindings: ["orca": "x"])
        let open = Repository(fullName: "O/Api")
        let repos = [OrcaRepo(id: "1", path: "/a", displayName: "api", canonicalKey: "github.com/o/api"),
                     OrcaRepo(id: "2", path: "/b", displayName: "bound", canonicalKey: "github.com/o/bound")]
        #expect(OrcaLinker.bindings(for: [bound, open], launcherId: "orca", orcaRepos: repos) == [open.id: "1"])
    }
}

@Suite struct DescribeTests {
    func localized(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .resources) }

    @Test func engine() {
        #expect(AppModel.describe(EngineError.ruleNotFound("r1")) == localized("Rule not found: \("r1")"))
        #expect(AppModel.describe(EngineError.interruptedLaunch) == localized("Pilotboat quit while launching"))
    }

    @Test func command() {
        #expect(AppModel.describe(CommandError.executableNotFound("orca")) == localized("\("orca") was not found on PATH"))
    }

    @Test func gitHub() {
        #expect(AppModel.describe(GitHubError.unauthorized) == localized("The GitHub token is invalid or expired"))
        #expect(AppModel.describe(GitHubError.http(status: 502, body: "")) == localized("GitHub returned HTTP \(502)"))
    }

    @Test func orca() {
        #expect(AppModel.describe(OrcaLauncherError.notBound("o/api")) == localized("\("o/api") is not linked to an Orca repository"))
        #expect(AppModel.describe(OrcaLauncherError.commandFailed("boom")) == "boom")
        #expect(AppModel.describe(OrcaRetryableError(retryToken: "t", message: "retry me")) == "retry me")
    }

    @Test func script() {
        let code: Int32 = 2
        #expect(AppModel.describe(ScriptLauncherError.failed(exitCode: code, stderrTail: "tail"))
            == localized("The launcher script exited with code \(code)") + "\ntail")
        #expect(AppModel.describe(ScriptLauncherError.timedOut) == localized("The launcher script timed out"))
    }

    @Test func configStore() {
        #expect(AppModel.describe(ConfigStoreError.newerSchema(found: 9))
            == localized("The settings file was saved by a newer version of Pilotboat. Update Pilotboat to use it"))
    }

    @Test func configEdit() {
        let names = "a, b"
        #expect(AppModel.describe(ConfigEditError.launcherInUse(["a", "b"])) == localized("Used by: \(names). Change those automations first"))
    }

    @Test func passesAppErrorThroughAndMasksTokens() {
        #expect(AppModel.describe(AppError("plain")) == "plain")
        #expect(!AppModel.describe(AppError("token ghp_abcdef123")).contains("ghp_abcdef123"))
    }
}
