import Core
import LauncherOrca
import SwiftUI

struct RepositoryDetail: View {
    @Environment(AppModel.self) private var model
    let repo: Repository

    private let kinds = EventKind.supported.sorted { $0.rawValue < $1.rawValue }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { repo.monitoring }, set: { on in update { $0.monitoring = on } })) {
                    Captioned("Monitoring", caption: "Events from this repository are ignored while off")
                }
            }
            Section {
                ForEach(kinds, id: \.self) { kind in row(kind) }
            } header: { Text("Automations here", bundle: .resources) }
            Section {
                ForEach(model.config.launchers) { launcher in
                    if launcher.type == "orca" {
                        OrcaBindingRow(repo: repo, launcher: launcher, showId: model.config.launchers.count > 1)
                    } else {
                        ScriptBindingRow(repo: repo, launcher: launcher)
                    }
                }
            } header: { Text("Agent launcher", bundle: .resources) }
        }
        .formStyle(.grouped)
        .navigationTitle(repo.fullName)
    }

    private func update(_ change: @escaping @Sendable (inout Repository) -> Void) {
        let id = repo.id
        Task { await model.updateConfig { config in if let i = config.repositories.firstIndex(where: { $0.id == id }) { change(&config.repositories[i]) } } }
    }

    private func applying(_ cell: OverviewCell) -> Rule? {
        switch cell {
        case .rule(let rule): rule
        case .conditional(let rules): rules.first
        default: nil
        }
    }

    private func row(_ kind: EventKind) -> some View {
        let cell = model.overview(repo: repo, kind: kind)
        let rule = applying(cell)
        let muted = repo.mutedEventKinds.contains(kind)
        return LabeledContent(kind.shortName) {
            HStack {
                switch cell {
                case .rule(let rule): Text(rule.name)
                case .conditional(let rules): Text(rules.map(\.name).joined(separator: ", "))
                case .muted: Text("Ignored here", bundle: .resources).foregroundStyle(.secondary)
                case .none: Text("None", bundle: .resources).foregroundStyle(.secondary)
                case .repoOff: Text("Monitoring is off", bundle: .resources).foregroundStyle(.secondary)
                }
                Menu {
                    Button(muted ? String(localized: "Stop ignoring", bundle: .resources) : String(localized: "Ignore this trigger here", bundle: .resources)) {
                        update { if muted { $0.mutedEventKinds.remove(kind) } else { $0.mutedEventKinds.insert(kind) } }
                    }
                    Button(String(localized: "Customize for this repository…", bundle: .resources)) { if let rule { customize(rule) } }
                        .disabled(rule == nil)
                    Button(String(localized: "Open automation", bundle: .resources)) { if let rule { model.router.show(section: .automations, automationId: rule.id) } }
                        .disabled(rule == nil)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(Text("More", bundle: .resources))
            }
        }
    }

    private func customize(_ rule: Rule) {
        var copy = rule
        copy.id = UUID().uuidString
        copy.name += " (repo)"
        copy.priority = (model.config.rules.map(\.priority).max() ?? 0) + 1
        copy.repoScope = .only([repo.id])
        var template = model.config.promptTemplate(id: rule.promptTemplateId)
        template?.id = UUID().uuidString
        template?.name += " (repo)"
        if let template { copy.promptTemplateId = template.id }
        let (newRule, newTemplate) = (copy, template)
        Task {
            await model.updateConfig { config in
                if let newTemplate { config.promptTemplates.append(newTemplate) }
                config.rules.append(newRule)
            }
            model.router.show(section: .automations, automationId: newRule.id)
        }
    }
}

private struct OrcaBindingRow: View {
    @Environment(AppModel.self) private var model
    let repo: Repository
    let launcher: LauncherConfig
    let showId: Bool
    @State private var repos: [OrcaRepo] = []

    private var bound: String? { repo.launcherBindings[launcher.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(showId ? String(localized: "Orca repository (\(launcher.id))", bundle: .resources) : String(localized: "Orca repository", bundle: .resources),
                   selection: Binding(get: { bound }, set: set)) {
                Text("Not linked", bundle: .resources).tag(String?.none)
                ForEach(repos, id: \.id) { Text($0.displayName).tag(Optional($0.id)) }
                if let bound, !repos.contains(where: { $0.id == bound }) { Text(bound).tag(Optional(bound)) }
            }
            if let path = repos.first(where: { $0.id == bound })?.path {
                Text(path).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { repos = (try? await model.orcaRepos(launcherId: launcher.id)) ?? [] }
    }

    private func set(_ id: String?) {
        let (repoId, launcherId) = (repo.id, launcher.id)
        Task { await model.updateConfig { config in if let i = config.repositories.firstIndex(where: { $0.id == repoId }) { config.repositories[i].launcherBindings[launcherId] = id } } }
    }
}

private struct ScriptBindingRow: View {
    @Environment(AppModel.self) private var model
    let repo: Repository
    let launcher: LauncherConfig

    private var path: String? { repo.launcherBindings[launcher.id] }

    var body: some View {
        LabeledContent(String(localized: "Local checkout (\(launcher.id))", bundle: .resources)) {
            HStack {
                Text(path ?? String(localized: "Not set", bundle: .resources)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button { if let chosen = chooseFile(directories: true) { set(chosen) } } label: { Text("Choose…", bundle: .resources) }
                if path != nil { Button { set(nil) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).accessibilityLabel(Text("Clear", bundle: .resources)) }
            }
        }
    }

    private func set(_ value: String?) {
        let (repoId, launcherId) = (repo.id, launcher.id)
        Task { await model.updateConfig { config in if let i = config.repositories.firstIndex(where: { $0.id == repoId }) { config.repositories[i].launcherBindings[launcherId] = value } } }
    }
}
