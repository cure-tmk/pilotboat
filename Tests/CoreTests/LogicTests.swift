import Foundation
import Testing
@testable import Core

@Suite struct PromptRendererTests {
    @Test func rendersLatestReviewAndCount() {
        let pr = makePR()
        let events = [
            reviewSubmitted(pr, id: 2, at: startDate + 10, by: "carol", bot: true, state: "CHANGES_REQUESTED"),
            reviewSubmitted(pr, id: 1, at: startDate, by: "bob"),
        ]
        let template = "{{pr.url}} #{{ pr.number }} {{repo.fullName}} {{event.kind}} {{review.author}}/{{review.state}}/{{review.isBot}}/{{review.count}} {{nope}}"
        #expect(PromptRenderer.render(template: template, events: events)
            == "https://github.com/o/api/pull/1 #1 o/api reviewSubmitted carol/CHANGES_REQUESTED/true/2 {{nope}}")
    }

    @Test func validatesUnsupportedAndUnknownVariables() {
        let template = "{{pr.url}} {{review.author}} {{pr.body}} {{pr.title}}"
        #expect(PromptRenderer.validate(template: template, kind: .reviewRequested) == ["review.author", "pr.body"])
        #expect(PromptRenderer.validate(template: template, kind: .reviewSubmitted) == ["pr.body"])
        #expect(PromptRenderer.usesUntrustedVariables(template))
        #expect(!PromptRenderer.usesUntrustedVariables("{{pr.url}}"))
    }
}

@Suite struct PresetTests {
    @Test func installCreatesDisabledPresetsOnce() {
        var config = Config()
        Presets.install(into: &config, launcherId: "orca")
        Presets.install(into: &config, launcherId: "orca")
        #expect(config.rules.map(\.id) == [Presets.reviewRequestedId, Presets.reviewReceivedId])
        #expect(config.rules.allSatisfy { !$0.enabled && $0.executionMode == .auto })
        #expect(config.rules[0].conditions == [.includeDraft(false)] && config.rules[0].workspacePolicy == .reusePrevious)
        #expect(config.rules[1].conditions.isEmpty && config.rules[1].workspacePolicy == .reuseOrCreate)
        #expect(config.promptTemplates.allSatisfy { !PromptRenderer.usesUntrustedVariables($0.body) })
        #expect(config.presetState[Presets.reviewRequestedId] == PresetState(version: 2))
    }

    @Test func upgradeRewritesOnlyUntouchedPresets() {
        var config = Config()
        Presets.install(into: &config, launcherId: "orca")
        config.promptTemplates[1].body += " Edited."
        let bodies = Presets.bodies.mapValues { $0.merging([3: "v3"]) { a, _ in a } }
        Presets.upgrade(&config, bodies: bodies, to: 3)
        #expect(config.promptTemplates[0].body == "v3")
        #expect(config.presetState[Presets.reviewRequestedId] == PresetState(version: 3))
        #expect(config.promptTemplates[1].body.hasSuffix("Edited."))
        #expect(config.presetState[Presets.reviewReceivedId] == PresetState(editedByUser: true, version: 2))
    }

    @Test func upgradeFromVersionOneSkipsUnchangedBodies() {
        var config = Config()
        Presets.install(into: &config, launcherId: "orca")
        for id in [Presets.reviewRequestedId, Presets.reviewReceivedId] {
            config.presetState[id] = PresetState(version: 1)
            config.promptTemplates[config.promptTemplates.firstIndex { $0.id == id }!].body = Presets.bodies[id]![1]! + " Edited."
        }
        Presets.upgrade(&config)
        #expect(config.presetState[Presets.reviewRequestedId] == PresetState(editedByUser: true, version: 1))
        #expect(config.presetState[Presets.reviewReceivedId] == PresetState(version: 2))
        #expect(Presets.outdatedEditedPresets(in: config) == [Presets.reviewRequestedId])
    }
}

@Suite struct ConfigExportTests {
    func sourceConfig() -> Config {
        var config = baseConfig()
        config.repositories[1].mutedEventKinds = [.reviewRequested]
        config.repositories[0].launcherBindings = ["main": "local-id"]
        config.launchers.append(LauncherConfig(id: "script", type: "script", settings: .object(["executable": .string("/bin/x"), "flag": .bool(true)])))
        config.rules.append(Rule(id: "api", name: "api", priority: 5, eventKind: .reviewRequested, repoScope: .only([apiRepo.id]),
                                 settleSeconds: 0, launcherId: "script", workspacePolicy: .alwaysNew, promptTemplateId: "rr"))
        return config
    }

    @Test func exportStripsMachineSpecificValues() throws {
        let exported = ConfigExport.export(sourceConfig())
        let json = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
        #expect(!json.contains("/bin/x") && !json.contains("local-id") && !json.contains(apiRepo.id.uuidString))
        #expect(exported.rules[2].repoScope == .only(["github.com/o/api"]))
    }

    @Test func roundTripIntoEmptyConfigKeepsReferences() throws {
        let data = try JSONEncoder().encode(ConfigExport.export(sourceConfig()))
        let result = ConfigExport.importing(try JSONDecoder().decode(ExportedConfig.self, from: data), into: Config(), conflictPolicy: .rename)
        let config = result.config
        let api = try #require(config.repository(host: "github.com", fullName: "o/api"))
        #expect(api.id != apiRepo.id && api.launcherBindings.isEmpty)
        #expect(config.repository(host: "github.com", fullName: "o/web")?.mutedEventKinds == [.reviewRequested])
        #expect(config.rule(id: "api")?.repoScope == .only([api.id]))
        #expect(config.rules.map(\.promptTemplateId) == ["rr", "rs", "rr"])
        #expect(config.launcher(id: "script")?.settings == .object(["flag": .bool(true)]))
        #expect(result.conflicts.isEmpty && result.launchersNeedingExecutable == ["script"])
    }

    @Test func conflictsAreOverwrittenOrRenamed() throws {
        let exported = ConfigExport.export(sourceConfig())
        var base = baseConfig()
        base.promptTemplates[0].body = "local"

        let overwritten = ConfigExport.importing(exported, into: base, conflictPolicy: .overwrite)
        #expect(overwritten.conflicts.sorted() == ["rr", "rr", "rs", "rs"])
        #expect(overwritten.config.promptTemplate(id: "rr")?.body == "Review {{pr.url}}")
        #expect(overwritten.config.rules.count == 3)

        let renamed = ConfigExport.importing(exported, into: base, conflictPolicy: .rename)
        #expect(renamed.config.promptTemplate(id: "rr")?.body == "local")
        #expect(renamed.config.rules.count == 5)
        let imported = try #require(renamed.config.rules.last)
        #expect(imported.id == "api" && imported.promptTemplateId != "rr")
        #expect(renamed.config.promptTemplate(id: imported.promptTemplateId)?.body == "Review {{pr.url}}")
    }
}

@Suite struct InMemoryStateStoreTests {
    @Test func writeRollsBackOnThrow() throws {
        let store = InMemoryStateStore()
        let run = Run(state: .queued, ruleId: "r", repo: "o/api", prNumber: 1, createdAt: startDate, updatedAt: startDate)
        #expect(throws: FakeError.self) {
            try store.write { s in
                try s.insertRun(run)
                try s.setBaseline(repoId: apiRepo.id, kind: .reviewRequested, at: startDate)
                throw FakeError(description: "boom")
            }
        }
        #expect(try store.read { try $0.run(id: run.id) == nil && !$0.hasAnyBaseline() })
        try store.write { try $0.insertRun(run) }
        #expect(try store.read { try $0.recentRuns(limit: 5) } == [run])
    }

    @Test func rejectsWhatSQLiteRejects() throws {
        let store = InMemoryStateStore()
        let settling = Run(state: .settling, ruleId: "r", repo: "o/api", prNumber: 1, createdAt: startDate, updatedAt: startDate)
        let event = reviewRequested(makePR(), at: startDate)
        try store.write { try $0.insertRun(settling); try $0.attach(event, toRun: settling.id) }
        #expect(throws: InMemoryStateStore.ConstraintViolation.self) { try store.write { try $0.insertRun(settling) } }
        #expect(throws: InMemoryStateStore.ConstraintViolation.self) { try store.write { try $0.attach(event, toRun: settling.id) } }
        var second = Run(state: .settling, ruleId: "r", repo: "o/api", prNumber: 1, createdAt: startDate, updatedAt: startDate)
        #expect(throws: InMemoryStateStore.ConstraintViolation.self) { try store.write { try $0.insertRun(second) } }
        second.state = .queued
        try store.write { try $0.insertRun(second) }
        second.state = .settling
        #expect(throws: InMemoryStateStore.ConstraintViolation.self) { try store.write { try $0.updateRun(second) } }
    }

    @Test func ordersRunsByCreationThenInsertion() throws {
        let store = InMemoryStateStore()
        func run(_ created: TimeInterval, _ ref: String) -> Run {
            Run(state: .launched, ruleId: ref, repo: "o/api", prNumber: 1, workspaceRef: ref, createdAt: startDate + created, updatedAt: startDate)
        }
        let (late, early, tie) = (run(10, "late"), run(0, "early"), run(10, "tie"))
        try store.write { s in for r in [late, early, tie] { try s.insertRun(r) } }
        try store.read { (s: any StateAccess) throws in
            #expect(try s.recentRuns(limit: 3).map(\.ruleId) == ["tie", "late", "early"])
            #expect(try s.runs(state: .launched).map(\.ruleId) == ["early", "late", "tie"])
            #expect(try s.latestRunWithWorkspace(repo: "o/api", prNumber: 1)?.ruleId == "tie")
        }
    }
}
