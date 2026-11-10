import Core
import SwiftUI

struct AutomationsPage: View {
    @Environment(AppModel.self) private var model
    @State private var draft: AutomationDraft?
    @State private var original: AutomationDraft?
    @State private var pendingSelection: String?
    @State private var confirmsDiscard = false
    @State private var deleting: Rule?

    private var config: Config { model.config }
    private var isDirty: Bool { draft != original }

    private var rules: [Rule] { config.rankedRules }

    private var selectedRule: Rule? { model.router.automationId.flatMap(config.rule(id:)) }

    var body: some View {
        Group {
            if config.rules.isEmpty {
                ContentUnavailableView {
                    Label { Text("No automations", bundle: .resources) } icon: { Image(systemName: "bolt.badge.automatic") }
                } description: {
                    Text("An automation starts an agent when something happens on one of your pull requests", bundle: .resources)
                } actions: {
                    newMenu.fixedSize()
                }
            } else {
                HSplitView {
                    list.frame(minWidth: 300, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
                    editorPane.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                newMenu
                Button { duplicate() } label: {
                    Label { Text("Duplicate", bundle: .resources) } icon: { Image(systemName: "plus.square.on.square") }
                }
                .disabled(selectedRule == nil)
                Button { deleting = selectedRule } label: {
                    Label { Text("Delete", bundle: .resources) } icon: { Image(systemName: "trash") }
                }
                .disabled(selectedRule == nil)
            }
        }
        .onChange(of: model.router.automationId, initial: true) { load() }
        .onChange(of: model.config) { if !isDirty { load() } }
        .alert(Text("Discard unsaved changes?", bundle: .resources), isPresented: $confirmsDiscard) {
            Button(role: .destructive) { model.router.automationId = pendingSelection } label: { Text("Discard", bundle: .resources) }
            Button(role: .cancel) {} label: { Text("Keep editing", bundle: .resources) }
        } message: {
            Text("Your changes to “\(draft?.rule.name ?? "")” have not been saved", bundle: .resources)
        }
        .alert(Text("Delete “\(deleting?.name ?? "")”?", bundle: .resources),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { rule in
            Button(role: .destructive) { delete(rule) } label: { Text("Delete automation", bundle: .resources) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .resources) }
        } message: { _ in
            Text("This cannot be undone", bundle: .resources)
        }
    }

    private var list: some View {
        List(selection: Binding(get: { model.router.automationId }, set: select)) {
            Section {
                ForEach(rules) { rule in row(rule).tag(rule.id) }
                    .onMove(perform: move)
            } header: {
                Text("When several automations match, the one higher in the list runs", bundle: .resources)
                    .font(.caption).textCase(nil)
            }
        }
    }

    private func row(_ rule: Rule) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { rule.enabled }, set: { setEnabled(rule.id, $0) })) { Text(rule.name) }
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).lineLimit(1)
                Text(rule.summary(config: config)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer(minLength: 4)
            if !rule.eventKind.isSupported {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(rule.eventKind.triggerDescription)
            }
        }
    }

    @ViewBuilder private var editorPane: some View {
        if let binding = Binding($draft) {
            AutomationEditor(draft: binding, isDirty: isDirty, save: save, revert: load)
                .id(binding.wrappedValue.rule.id)
        } else {
            ContentUnavailableView {
                Label { Text("Select an automation", bundle: .resources) } icon: { Image(systemName: "bolt.badge.automatic") }
            }
        }
    }

    private var newMenu: some View {
        Menu {
            ForEach([EventKind.reviewRequested, .reviewSubmitted], id: \.self) { kind in
                Button(kind.triggerName) { create(kind) }
            }
        } label: {
            Label { Text("New automation", bundle: .resources) } icon: { Image(systemName: "plus") }
        }
    }

    // MARK: Selection and draft

    private func select(_ id: String?) {
        guard id != model.router.automationId else { return }
        if isDirty {
            pendingSelection = id
            confirmsDiscard = true
        } else {
            model.router.automationId = id
        }
    }

    private func load() {
        guard let rule = selectedRule else { draft = nil; original = nil; return }
        let template = config.promptTemplate(id: rule.promptTemplateId)
            ?? PromptTemplate(id: rule.promptTemplateId, name: rule.name, body: "")
        draft = AutomationDraft(rule: rule, template: template)
        original = draft
    }

    private func save() {
        guard let draft else { return }
        let (rule, body) = (draft.rule, draft.template.body)
        Task {
            // A failed save leaves the config unchanged; keep the draft so nothing is lost.
            if await model.updateConfig({ $0.saveRule(rule, templateBody: body) }) { load() }
        }
    }

    // MARK: Actions

    private func setEnabled(_ id: String, _ on: Bool) {
        if draft?.rule.id == id { draft?.rule.enabled = on; original?.rule.enabled = on }
        model.edit { config in
            if let i = config.rules.firstIndex(where: { $0.id == id }) { config.rules[i].enabled = on }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = rules.map(\.id)
        ordered.move(fromOffsets: source, toOffset: destination)
        let order = ordered
        model.edit { $0.setRuleOrder(order) }
    }

    private func create(_ kind: EventKind) {
        let presetId = kind == .reviewRequested ? Presets.reviewRequestedId : Presets.reviewReceivedId
        let body = config.promptTemplate(id: presetId)?.body ?? ""
        let launcherId = config.launchers.first?.id ?? Bootstrap.defaultOrcaLauncherId
        let name = kind.shortName
        let (id, templateId) = (UUID().uuidString, UUID().uuidString)
        model.edit { $0.addRule(id: id, templateId: templateId, name: name, kind: kind, launcherId: launcherId, templateBody: body) }
        select(id)
    }

    private func duplicate() {
        guard let rule = selectedRule else { return }
        let (id, name) = (rule.id, String(localized: "\(rule.name) copy", bundle: .resources))
        let (newId, newTemplateId) = (UUID().uuidString, UUID().uuidString)
        if model.edit({ $0.duplicateRule(id: id, newId: newId, newTemplateId: newTemplateId, name: name) }) != nil { select(newId) }
    }

    private func delete(_ rule: Rule) {
        if model.router.automationId == rule.id {
            draft = nil; original = nil
            model.router.automationId = nil
        }
        let id = rule.id
        model.edit { $0.removeRule(id: id) }
    }
}
