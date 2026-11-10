import Foundation

public enum ConfigEditError: Error, Hashable, Sendable {
    /// Names of the rules that still use the launcher.
    case launcherInUse([String])
}

extension EventKind {
    /// Filters a new automation starts with.
    public var defaultConditions: [Condition] { self == .reviewRequested ? [.includeDraft(false)] : [] }
    public var defaultSettleSeconds: Int { self == .reviewRequested ? 0 : 120 }
    public var defaultWorkspacePolicy: WorkspacePolicy { self == .reviewRequested ? .reusePrevious : .reuseOrCreate }
}

extension Rule {
    /// `.any` when the rule has no actor condition.
    public var actorKind: ActorKind {
        get { for case .actorKind(let kind) in conditions { return kind }; return .any }
        set { replaceCondition(newValue == .any ? nil : .actorKind(newValue)) { if case .actorKind = $0 { true } else { false } } }
    }

    public var includesDrafts: Bool {
        get { for case .includeDraft(let include) in conditions { return include }; return true }
        set { replaceCondition(newValue ? nil : .includeDraft(false)) { if case .includeDraft = $0 { true } else { false } } }
    }

    public var requiredLabels: [String] {
        get { for case .labelsInclude(let labels) in conditions { return labels }; return [] }
        set { replaceCondition(newValue.isEmpty ? nil : .labelsInclude(newValue)) { if case .labelsInclude = $0 { true } else { false } } }
    }

    public var excludedLabels: [String] {
        get { for case .labelsExclude(let labels) in conditions { return labels }; return [] }
        set { replaceCondition(newValue.isEmpty ? nil : .labelsExclude(newValue)) { if case .labelsExclude = $0 { true } else { false } } }
    }

    private mutating func replaceCondition(_ condition: Condition?, matching: (Condition) -> Bool) {
        if let index = conditions.firstIndex(where: matching) {
            if let condition { conditions[index] = condition } else { conditions.remove(at: index) }
        } else if let condition {
            conditions.append(condition)
        }
    }
}

extension Repository {
    public static let defaultHost = "github.com"

    /// `owner/name` with the characters GitHub allows.
    public static func isValidFullName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) != nil
    }
}

extension String {
    /// The first `length` characters followed by "…", or the string itself when it already fits.
    public func truncated(to length: Int) -> String {
        count <= length ? self : prefix(length) + "…"
    }
}

extension Config {
    /// Rules in matching order: priority descending, then config order.
    public var rankedRules: [Rule] { RuleMatcher.ranked(rules) }

    public func launchers(ofType type: String) -> [LauncherConfig] { launchers.filter { $0.type == type } }

    private var nextPriority: Int { (rules.map(\.priority).max() ?? -1) + 1 }

    /// Adds a disabled rule with its own template and the trigger's defaults, ranked first. Returns the rule id.
    @discardableResult
    public mutating func addRule(id: String = UUID().uuidString, templateId: String = UUID().uuidString,
                                 name: String, kind: EventKind, launcherId: LauncherID, templateBody: String) -> String {
        let template = PromptTemplate(id: templateId, name: name, body: templateBody)
        let rule = Rule(id: id, name: name, priority: nextPriority, eventKind: kind, conditions: kind.defaultConditions,
                        settleSeconds: kind.defaultSettleSeconds, launcherId: launcherId,
                        workspacePolicy: kind.defaultWorkspacePolicy, promptTemplateId: template.id)
        promptTemplates.append(template)
        rules.append(rule)
        return rule.id
    }

    /// Inserts a disabled copy named `name` right after the original, with the same priority and a copy of its template.
    @discardableResult
    public mutating func duplicateRule(id: String, newId: String = UUID().uuidString, newTemplateId: String = UUID().uuidString,
                                       name: String) -> String? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = rules[index]
        copy.id = newId
        copy.name = name
        copy.enabled = false
        copy.promptTemplateId = copyTemplate(of: rules[index], id: newTemplateId, name: name)
        rules.insert(copy, at: index + 1)
        return copy.id
    }

    /// Adds a copy scoped to one repository that outranks every existing rule, with its own template.
    @discardableResult
    public mutating func customizeRule(id: String, forRepository repoId: UUID, nameSuffix: String,
                                       newId: String = UUID().uuidString, newTemplateId: String = UUID().uuidString) -> String? {
        guard var copy = rule(id: id) else { return nil }
        copy.id = newId
        copy.name += nameSuffix
        copy.priority = nextPriority
        copy.repoScope = .only([repoId])
        copy.promptTemplateId = copyTemplate(of: copy, id: newTemplateId, name: (promptTemplate(id: copy.promptTemplateId)?.name ?? copy.name) + nameSuffix)
        rules.append(copy)
        return copy.id
    }

    private mutating func copyTemplate(of rule: Rule, id: String, name: String) -> String {
        let template = PromptTemplate(id: id, name: name, body: promptTemplate(id: rule.promptTemplateId)?.body ?? "")
        promptTemplates.append(template)
        return template.id
    }

    /// `ids` top first; the first gets the highest priority. Rules not listed keep theirs.
    public mutating func setRuleOrder(_ ids: [String]) {
        let priorities = Dictionary(ids.enumerated().map { ($1, ids.count - 1 - $0) }, uniquingKeysWith: { a, _ in a })
        for i in rules.indices { if let p = priorities[rules[i].id] { rules[i].priority = p } }
    }

    /// Replaces the stored rule and its template body. Priority is kept, since `setRuleOrder` owns it.
    public mutating func saveRule(_ rule: Rule, templateBody: String) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        var rule = rule
        rule.priority = rules[i].priority
        rules[i] = rule
        if let t = promptTemplates.firstIndex(where: { $0.id == rule.promptTemplateId }) {
            guard promptTemplates[t].body != templateBody else { return }
            promptTemplates[t].body = templateBody
            presetState[rule.promptTemplateId]?.editedByUser = true
        } else {
            promptTemplates.append(PromptTemplate(id: rule.promptTemplateId, name: rule.name, body: templateBody))
        }
    }

    /// Also removes the rule's template once no other rule uses it.
    public mutating func removeRule(id: String) {
        guard let rule = rule(id: id) else { return }
        rules.removeAll { $0.id == id }
        if !rules.contains(where: { $0.promptTemplateId == rule.promptTemplateId }) {
            promptTemplates.removeAll { $0.id == rule.promptTemplateId }
        }
    }

    /// Also drops the repository from every `.only` scope.
    public mutating func removeRepository(id: UUID) {
        repositories.removeAll { $0.id == id }
        for i in rules.indices {
            if case .only(let ids) = rules[i].repoScope { rules[i].repoScope = .only(ids.filter { $0 != id }) }
        }
    }

    /// Uses `id` when given and free; otherwise `type`, then `type-2`, `type-3`, …
    @discardableResult
    public mutating func addLauncher(id requested: LauncherID? = nil, type: String, settings: JSONValue = .object([:])) -> LauncherID {
        if let requested, launcher(id: requested) == nil {
            launchers.append(LauncherConfig(id: requested, type: type, settings: settings))
            return requested
        }
        var id = type, n = 2
        while launcher(id: id) != nil { id = "\(type)-\(n)"; n += 1 }
        launchers.append(LauncherConfig(id: id, type: type, settings: settings))
        return id
    }

    /// Throws `ConfigEditError.launcherInUse` while a rule uses it; otherwise also clears repository bindings to it.
    public mutating func removeLauncher(id: LauncherID) throws {
        let users = rules.filter { $0.launcherId == id }.map(\.name)
        guard users.isEmpty else { throw ConfigEditError.launcherInUse(users) }
        launchers.removeAll { $0.id == id }
        for i in repositories.indices { repositories[i].launcherBindings[id] = nil }
    }

    public mutating func useLauncherForPresets(_ id: LauncherID) {
        for i in rules.indices where [Presets.reviewRequestedId, Presets.reviewReceivedId].contains(rules[i].id) {
            rules[i].launcherId = id
        }
    }
}
