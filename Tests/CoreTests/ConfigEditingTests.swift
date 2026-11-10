import Foundation
import Testing
@testable import Core

@Suite struct ConfigEditingTests {
    @Test func addRuleUsesTriggerDefaultsAndOwnTemplate() throws {
        var config = baseConfig()
        config.rules[1].priority = 4
        let id = config.addRule(name: "New", kind: .reviewRequested, launcherId: "main", templateBody: "Body")
        let rule = try #require(config.rule(id: id))
        #expect(!rule.enabled && rule.priority == 5 && rule.name == "New")
        #expect(rule.conditions == [.includeDraft(false)] && rule.settleSeconds == 0 && rule.workspacePolicy == .reusePrevious)
        #expect(!["rr", "rs"].contains(rule.promptTemplateId))
        #expect(config.promptTemplate(id: rule.promptTemplateId)?.body == "Body")
        #expect(config.rankedRules.first?.id == id)

        var empty = Config()
        let firstId = empty.addRule(name: "x", kind: .reviewSubmitted, launcherId: "main", templateBody: "")
        let first = try #require(empty.rule(id: firstId))
        #expect(first.priority == 0 && first.settleSeconds == 120 && first.workspacePolicy == .reuseOrCreate && first.conditions.isEmpty)
    }

    @Test func duplicateRuleInsertsDisabledCopyAfterOriginal() throws {
        var config = baseConfig()
        config.rules[0].priority = 3
        let duplicated = config.duplicateRule(id: "rr", name: "rr copy")
        let id = try #require(duplicated)
        #expect(config.rules.map(\.id) == ["rr", id, "rs"])
        let copy = config.rules[1]
        #expect(!copy.enabled && copy.priority == 3 && copy.name == "rr copy" && copy.eventKind == .reviewRequested)
        #expect(copy.promptTemplateId != "rr" && config.promptTemplate(id: copy.promptTemplateId)?.body == "Review {{pr.url}}")
        #expect(config.duplicateRule(id: "missing", name: "x") == nil)
    }

    @Test func customizeRuleScopesToRepositoryAndOutranks() throws {
        var config = baseConfig()
        let customized = config.customizeRule(id: "rs", forRepository: apiRepo.id, nameSuffix: " (repo)")
        let id = try #require(customized)
        let rule = try #require(config.rule(id: id))
        #expect(rule.name == "rs (repo)" && rule.repoScope == .only([apiRepo.id]) && rule.priority == 1)
        let template = try #require(config.promptTemplate(id: rule.promptTemplateId))
        #expect(template.id != "rs" && template.name == "rs (repo)" && template.body == config.promptTemplate(id: "rs")?.body)
        #expect(config.customizeRule(id: "missing", forRepository: apiRepo.id, nameSuffix: "") == nil)
    }

    @Test func explicitIdsAreUsedVerbatim() throws {
        var config = baseConfig()
        #expect(config.addRule(id: "n", templateId: "nt", name: "New", kind: .reviewRequested, launcherId: "main", templateBody: "B") == "n")
        #expect(config.rule(id: "n")?.promptTemplateId == "nt" && config.promptTemplate(id: "nt")?.body == "B")
        #expect(config.duplicateRule(id: "rr", newId: "d", newTemplateId: "dt", name: "copy") == "d")
        #expect(config.rule(id: "d")?.promptTemplateId == "dt" && config.promptTemplate(id: "dt") != nil)
        #expect(config.customizeRule(id: "rs", forRepository: apiRepo.id, nameSuffix: "!", newId: "c", newTemplateId: "ct") == "c")
        #expect(config.rule(id: "c")?.promptTemplateId == "ct" && config.promptTemplate(id: "ct") != nil)
        #expect(config.addLauncher(id: "mine", type: "script") == "mine")
        #expect(config.addLauncher(id: "mine", type: "script") == "script")

        var replay = baseConfig()
        _ = replay.addRule(id: "n", templateId: "nt", name: "New", kind: .reviewRequested, launcherId: "main", templateBody: "B")
        var again = baseConfig()
        _ = again.addRule(id: "n", templateId: "nt", name: "New", kind: .reviewRequested, launcherId: "main", templateBody: "B")
        #expect(replay == again)
    }

    @Test func setRuleOrderAssignsContiguousPriorities() {
        var config = baseConfig()
        config.rules.append(Rule(id: "x", name: "x", priority: 9, eventKind: .reviewRequested, settleSeconds: 0,
                                 launcherId: "main", workspacePolicy: .alwaysNew, promptTemplateId: "rr"))
        config.setRuleOrder(["rs", "x", "rr"])
        #expect(config.rules.map(\.priority) == [0, 2, 1])
        #expect(config.rankedRules.map(\.id) == ["rs", "x", "rr"])
    }

    @Test func rankedRulesBreaksTiesByConfigOrder() {
        var config = baseConfig()
        config.rules[1].priority = 0
        #expect(config.rankedRules.map(\.id) == ["rr", "rs"])
    }

    @Test func saveRuleWritesRuleAndTemplateAndFlagsEditedPresets() throws {
        var config = Config()
        Presets.install(into: &config, launcherId: "main")
        var rule = try #require(config.rule(id: Presets.reviewRequestedId))
        rule.name = "Renamed"
        rule.priority = 99
        config.saveRule(rule, templateBody: config.promptTemplate(id: rule.promptTemplateId)!.body)
        #expect(config.rule(id: rule.id)?.name == "Renamed" && config.rule(id: rule.id)?.priority == 0)
        #expect(config.presetState[rule.id]?.editedByUser == false)

        config.saveRule(rule, templateBody: "Mine")
        #expect(config.promptTemplate(id: rule.promptTemplateId)?.body == "Mine")
        #expect(config.presetState[rule.id]?.editedByUser == true)

        var plain = baseConfig()
        plain.promptTemplates.removeAll { $0.id == "rr" }
        plain.saveRule(plain.rules[0], templateBody: "Restored")
        #expect(plain.promptTemplate(id: "rr")?.body == "Restored" && plain.presetState.isEmpty)
    }

    @Test func removeRuleDeletesOrphanedTemplateOnly() {
        var config = baseConfig()
        config.rules.append(Rule(id: "shares", name: "shares", priority: 0, eventKind: .reviewRequested, settleSeconds: 0,
                                 launcherId: "main", workspacePolicy: .alwaysNew, promptTemplateId: "rr"))
        config.removeRule(id: "rr")
        #expect(config.promptTemplate(id: "rr") != nil)
        config.removeRule(id: "shares")
        #expect(config.promptTemplate(id: "rr") == nil && config.rules.map(\.id) == ["rs"])
    }

    @Test func removeRepositoryScrubsScopes() {
        var config = baseConfig()
        config.rules[0].repoScope = .only([apiRepo.id, webRepo.id])
        config.removeRepository(id: apiRepo.id)
        #expect(config.repositories.map(\.id) == [webRepo.id])
        #expect(config.rules[0].repoScope == .only([webRepo.id]) && config.rules[1].repoScope == .all)
    }

    @Test func addLauncherNumbersIds() {
        var config = Config()
        #expect(config.addLauncher(type: "script") == "script")
        #expect(config.addLauncher(type: "script", settings: .object(["executable": .string("/x")])) == "script-2")
        #expect(config.addLauncher(type: "orca") == "orca")
        #expect(config.launchers(ofType: "script").map(\.id) == ["script", "script-2"])
        #expect(config.launcher(id: "script-2")?.settings["executable"] == .string("/x"))
    }

    @Test func removeLauncherRefusesWhileInUseAndClearsBindings() throws {
        var config = baseConfig()
        config.repositories[0].launcherBindings = ["main": "local"]
        #expect(throws: ConfigEditError.launcherInUse(["rr", "rs"])) { try config.removeLauncher(id: "main") }
        let other = config.addLauncher(type: "script")
        config.useLauncherForPresets(other)
        #expect(config.rules.allSatisfy { $0.launcherId == "main" })
        for i in config.rules.indices { config.rules[i].launcherId = other }
        try config.removeLauncher(id: "main")
        #expect(config.launcher(id: "main") == nil && config.repositories[0].launcherBindings.isEmpty)
    }

    @Test func useLauncherForPresetsTouchesOnlyPresets() {
        var config = baseConfig()
        Presets.install(into: &config, launcherId: "main")
        config.useLauncherForPresets("other")
        #expect(config.rules.map(\.launcherId) == ["main", "main", "other", "other"])
    }

    @Test func conditionAccessorsAddReplaceAndRemove() {
        var rule = baseConfig().rules[1]
        #expect(rule.actorKind == .human && rule.includesDrafts && rule.requiredLabels.isEmpty)
        rule.actorKind = .bot
        rule.includesDrafts = false
        rule.requiredLabels = ["a"]
        rule.excludedLabels = ["b"]
        #expect(rule.conditions == [.actorKind(.bot), .includeDraft(false), .labelsInclude(["a"]), .labelsExclude(["b"])])
        rule.actorKind = .any
        rule.includesDrafts = true
        rule.requiredLabels = []
        #expect(rule.conditions == [.labelsExclude(["b"])] && rule.excludedLabels == ["b"])
    }

    @Test func repositoryNameValidationAndTruncation() {
        #expect(Repository.isValidFullName("o/api.v2_x-y"))
        #expect(!Repository.isValidFullName("o") && !Repository.isValidFullName("o/a/b") && !Repository.isValidFullName("o /a"))
        #expect(Repository(fullName: "o/a").host == Repository.defaultHost)
        #expect("abcdef".truncated(to: 3) == "abc…" && "abc".truncated(to: 3) == "abc")
    }
}
