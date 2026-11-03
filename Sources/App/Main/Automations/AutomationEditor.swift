import Core
import LauncherOrca
import LauncherScript
import SwiftUI

struct AutomationDraft: Equatable {
    var rule: Rule
    var template: PromptTemplate
}

struct AutomationEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AutomationDraft
    let isDirty: Bool
    let save: () -> Void
    let revert: () -> Void

    @State private var showsFilters: Bool
    @State private var showsTiming: Bool
    @State private var confirmsAutomatic = false
    @State private var testing = false
    @State private var canReuseWorktrees = true

    init(draft: Binding<AutomationDraft>, isDirty: Bool, save: @escaping () -> Void, revert: @escaping () -> Void) {
        _draft = draft
        self.isDirty = isDirty; self.save = save; self.revert = revert
        let rule = draft.wrappedValue.rule
        _showsFilters = State(initialValue: Set(rule.conditions) != Set(rule.eventKind.defaultConditions))
        _showsTiming = State(initialValue: rule.settleSeconds != rule.eventKind.defaultSettleSeconds)
    }

    private var rule: Rule { draft.rule }
    private var invalidVariables: [String] { PromptRenderer.validate(template: draft.template.body, kind: rule.eventKind) }
    private var hasNoRepositories: Bool { rule.repoScope == .only([]) }
    private var isValid: Bool {
        !rule.name.trimmingCharacters(in: .whitespaces).isEmpty && invalidVariables.isEmpty && !hasNoRepositories
    }

    var body: some View {
        Form {
            Section {
                TextField(text: $draft.rule.name) { Text("Name", bundle: .resources) }
                Toggle(isOn: $draft.rule.enabled) { Text("Enabled", bundle: .resources) }
            }
            Section { triggerPicker; repositories; filters } header: { Text("When", bundle: .resources) }
            Section { action; instructions } header: { Text("Then", bundle: .resources) }
            Section { approval } header: { Text("Before starting", bundle: .resources) }
            if rule.eventKind != .reviewRequested { timing }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .sheet(isPresented: $testing) { AutomationTestSheet(rule: rule) }
        .task(id: rule.launcherId) { canReuseWorktrees = await launcherCanReuse() }
    }

    // MARK: When

    private var triggerPicker: some View {
        let kinds: [EventKind] = [.reviewRequested, .reviewSubmitted] + (rule.eventKind.isSupported ? [] : [rule.eventKind])
        return Picker(selection: Binding(get: { rule.eventKind }, set: { kind in
            draft.rule.eventKind = kind
            if kind == .reviewRequested { draft.rule.settleSeconds = 0 }
        })) {
            ForEach(kinds, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.triggerName)
                    Text(kind.triggerDescription).font(.caption).foregroundStyle(.secondary)
                }
                .tag(kind)
            }
        } label: { Text("Trigger", bundle: .resources) }
        .pickerStyle(.radioGroup)
    }

    @ViewBuilder private var repositories: some View {
        Picker(selection: Binding(get: { rule.repoScope != .all }, set: { draft.rule.repoScope = $0 ? .only([]) : .all })) {
            Text("All monitored", bundle: .resources).tag(false)
            Text("Only…", bundle: .resources).tag(true)
        } label: { Text("Repositories", bundle: .resources) }
        .pickerStyle(.segmented)
        if case .only(let ids) = rule.repoScope {
            let addable = model.config.repositories.filter { $0.monitoring && !ids.contains($0.id) }
            HStack(alignment: .top) {
                ChipList(items: ids.compactMap { model.config.repository(id: $0)?.fullName }) { name in
                    draft.rule.repoScope = .only(ids.filter { model.config.repository(id: $0)?.fullName != name })
                }
                Spacer()
                Menu {
                    ForEach(addable) { repo in
                        Button(repo.fullName) { draft.rule.repoScope = .only(ids + [repo.id]) }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(addable.isEmpty)
                .accessibilityLabel(Text("Add repository", bundle: .resources))
            }
            if ids.isEmpty {
                Text("Add at least one repository", bundle: .resources).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var filters: some View {
        DisclosureGroup(isExpanded: $showsFilters) {
            // Review requests carry no reviewer, so the reviewer filter would never apply to them.
            if rule.eventKind != .reviewRequested {
                Picker(selection: $draft.rule.reviewer) {
                    Text("Anyone", bundle: .resources).tag(ActorKind.any)
                    Text("People only", bundle: .resources).tag(ActorKind.human)
                    Text("Bots only", bundle: .resources).tag(ActorKind.bot)
                } label: { Text("Reviewer", bundle: .resources) }
            }
            Toggle(isOn: $draft.rule.includesDrafts) { Text("Include draft pull requests", bundle: .resources) }
            LabelField(title: "Only with labels", labels: $draft.rule.requiredLabels)
            LabelField(title: "Not with labels", labels: $draft.rule.excludedLabels)
        } label: { Text("Filters", bundle: .resources) }
    }

    // MARK: Then

    @ViewBuilder private var action: some View {
        Picker(selection: $draft.rule.workspacePolicy) {
            Captioned("Start an agent in a new worktree", caption: "Creates a fresh worktree for every run")
                .tag(WorkspacePolicy.alwaysNew)
            Captioned("Continue in the pull request's worktree",
                      caption: "Reuses the worktree and running agent for the PR's branch when there is one")
                .tag(WorkspacePolicy.reuseOrCreate)
        } label: { Text("Action", bundle: .resources) }
        .pickerStyle(.radioGroup)
        if model.config.launchers.count > 1 {
            Picker(selection: $draft.rule.launcherId) {
                ForEach(model.config.launchers) { Text(Self.name(of: $0)).tag($0.id) }
            } label: { Text("Agent launcher", bundle: .resources) }
        } else if let launcher = model.config.launchers.first {
            Text("Using \(Self.name(of: launcher))", bundle: .resources).font(.caption).foregroundStyle(.secondary)
        } else {
            Text("No agent launcher is set up", bundle: .resources).font(.caption).foregroundStyle(.red)
        }
        if rule.workspacePolicy == .reuseOrCreate, !canReuseWorktrees {
            warning(Text("This launcher cannot reuse worktrees, so every run starts in a new one", bundle: .resources))
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Instructions", bundle: .resources)
            TextEditor(text: $draft.template.body)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 110, maxHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            HStack {
                insertMenu
                Spacer()
            }
            if PromptRenderer.usesUntrustedVariables(draft.template.body) {
                warning(Text("The title is written by the PR author and can contain instructions for the agent", bundle: .resources))
            }
            if !invalidVariables.isEmpty {
                Text("Not available for this trigger: \(invalidVariables.map { "{{\($0)}}" }.joined(separator: ", "))", bundle: .resources)
                    .font(.caption).foregroundStyle(.red)
            }
            let sharedWith = model.config.rules.filter { $0.promptTemplateId == draft.template.id && $0.id != rule.id }.count
            if sharedWith > 0 {
                HStack {
                    Text("Also used by \(sharedWith) other automations — edits apply to all", bundle: .resources)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        draft.template = PromptTemplate(name: rule.name, body: draft.template.body)
                        draft.rule.promptTemplateId = draft.template.id
                    } label: { Text("Make a copy", bundle: .resources) }
                }
            }
        }
    }

    private var insertMenu: some View {
        let common = PromptRenderer.commonVariables
        return Menu {
            Section { variableButtons(common.filter { $0.hasPrefix("pr.") }) } header: { Text("Pull request", bundle: .resources) }
            Section { variableButtons(common.filter { $0.hasPrefix("repo.") }) } header: { Text("Repository", bundle: .resources) }
            Section { variableButtons(PromptRenderer.reviewVariables).disabled(rule.eventKind == .reviewRequested) } header: {
                Text("Review", bundle: .resources)
            }
        } label: { Text("Insert", bundle: .resources) }
        .fixedSize()
    }

    private func variableButtons(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            // Appends at the end: reading the cursor position needs the TextEditor selection API (macOS 15).
            Button { insert(name) } label: { Text(verbatim: "{{\(name)}}") }
        }
    }

    private func insert(_ name: String) {
        let body = draft.template.body
        let separator = body.isEmpty || body.last?.isWhitespace == true ? "" : " "
        draft.template.body += separator + "{{\(name)}}"
    }

    // MARK: Before starting, timing, footer

    private var approval: some View {
        Picker(selection: Binding(get: { rule.executionMode }, set: { mode in
            if mode == .auto { confirmsAutomatic = true } else { draft.rule.executionMode = mode }
        })) {
            Text("Ask me first (recommended)", bundle: .resources).tag(ExecutionMode.confirm)
            Text("Run automatically", bundle: .resources).tag(ExecutionMode.auto)
        } label: { Text("Before starting", bundle: .resources) }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .alert(Text("Run automatically?", bundle: .resources), isPresented: $confirmsAutomatic) {
            Button(role: .destructive) { draft.rule.executionMode = .auto } label: { Text("Run automatically", bundle: .resources) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .resources) }
        } message: {
            Text("Agents will start on this Mac as soon as this automation matches, without asking you. They work with your GitHub access, and pull request content can contain instructions for them", bundle: .resources)
        }
    }

    private var timing: some View {
        Section {
            DisclosureGroup(isExpanded: $showsTiming) {
                Stepper(value: Binding(get: { rule.settleSeconds / 60 }, set: { draft.rule.settleSeconds = $0 * 60 }), in: 0...10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wait for more reviews: \(rule.settleSeconds / 60) min", bundle: .resources)
                        Text("Reviews that arrive within this window are handled together", bundle: .resources)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } label: { Text("Timing", bundle: .resources) }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button { testing = true } label: { Text("Test with a pull request…", bundle: .resources) }
                    .disabled(isDirty)
                    .help(Text("Tests the saved version of this automation", bundle: .resources))
                Spacer()
                Button(action: revert) { Text("Revert", bundle: .resources) }
                    .disabled(!isDirty)
                Button(action: save) { Text("Save", bundle: .resources) }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || !isValid)
            }
            .padding(16)
        }
        .background(.bar)
    }

    private func warning(_ text: Text) -> some View {
        Label { text.font(.caption) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
    }

    private static func name(of launcher: LauncherConfig) -> String {
        launcher.type == OrcaLauncher.typeID ? String(localized: "Orca", bundle: .resources) : launcher.id
    }

    private func launcherCanReuse() async -> Bool {
        guard let launcher = model.config.launcher(id: rule.launcherId) else { return true }
        switch launcher.type {
        case OrcaLauncher.typeID:
            return model.orcaLauncher.capabilities.contains(.reuseWorkspace)
        case ScriptLauncher.typeID:
            guard case .string(let executable)? = launcher.settings["executable"] else { return false }
            return await model.scriptLauncher.capabilities(executable: executable).contains(.reuseWorkspace)
        default:
            return false
        }
    }
}

private struct LabelField: View {
    let title: LocalizedStringKey
    @Binding var labels: [String]
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(text: $text, prompt: Text("Type a label and press Return", bundle: .resources)) {
                Text(title, bundle: .resources)
            }
            .onSubmit {
                let label = text.trimmingCharacters(in: .whitespaces)
                if !label.isEmpty, !labels.contains(label) { labels.append(label) }
                text = ""
            }
            if !labels.isEmpty {
                ChipList(items: labels) { label in labels.removeAll { $0 == label } }
            }
        }
    }
}

fileprivate extension Rule {
    var reviewer: ActorKind {
        get { for case .actorKind(let kind) in conditions { return kind }; return .any }
        set { replaceCondition(newValue == .any ? nil : .actorKind(newValue)) { if case .actorKind = $0 { true } else { false } } }
    }

    var includesDrafts: Bool {
        get { for case .includeDraft(let include) in conditions { return include }; return true }
        set { replaceCondition(newValue ? nil : .includeDraft(false)) { if case .includeDraft = $0 { true } else { false } } }
    }

    var requiredLabels: [String] {
        get { for case .labelsInclude(let labels) in conditions { return labels }; return [] }
        set { replaceCondition(newValue.isEmpty ? nil : .labelsInclude(newValue)) { if case .labelsInclude = $0 { true } else { false } } }
    }

    var excludedLabels: [String] {
        get { for case .labelsExclude(let labels) in conditions { return labels }; return [] }
        set { replaceCondition(newValue.isEmpty ? nil : .labelsExclude(newValue)) { if case .labelsExclude = $0 { true } else { false } } }
    }

    mutating func replaceCondition(_ condition: Condition?, matching: (Condition) -> Bool) {
        if let index = conditions.firstIndex(where: matching) {
            if let condition { conditions[index] = condition } else { conditions.remove(at: index) }
        } else if let condition {
            conditions.append(condition)
        }
    }
}
