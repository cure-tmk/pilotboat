import Core
import LauncherOrca
import ProcessKit
import SwiftUI

struct SetupWindow: View {
    @Environment(AppModel.self) private var model
    @State private var step = 1
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                switch step {
                case 1: GitHubStep()
                case 2: LauncherStep(launcher: launcher)
                case 3: RepositoriesStep(launcher: launcher)
                default: AutomationsStep(includeExisting: $includeExisting)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let message = model.lastErrorMessage {
                HStack {
                    Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button(String(localized: "Dismiss", bundle: .resources)) { model.lastErrorMessage = nil }
                }
            }
            footer
        }
        .padding(16)
    }

    @State private var includeExisting = false
    @State private var launcher = LauncherChoice()

    private var footer: some View {
        HStack {
            Button(String(localized: "Back", bundle: .resources)) { step -= 1 }.disabled(step == 1 || busy)
            Spacer()
            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { Circle().fill($0 == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7) }
            }
            .accessibilityElement().accessibilityLabel(Text("Step \(step) of 4", bundle: .resources))
            Spacer()
            if step < 4 {
                Button(String(localized: "Continue", bundle: .resources)) { advance() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canContinue || busy)
            } else {
                Button(String(localized: "Finish", bundle: .resources)) {
                    Task { busy = true; await model.completeOnboarding(includeExistingReviewRequests: includeExisting); busy = false }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
    }

    private var canContinue: Bool {
        switch step {
        case 1: model.githubLogin != nil
        case 2: launcher.isValid && ["git", "claude"].allSatisfy { model.toolIsOK($0) }
        default: !model.config.repositories.isEmpty
        }
    }

    private func advance() {
        Task {
            busy = true
            if step == 2 { await launcher.apply(to: model) }
            step += 1
            busy = false
        }
    }
}

@MainActor @Observable
final class LauncherChoice {
    enum Kind { case orca, script }
    var kind: Kind = .script
    var agent = "claude"
    var scriptPath = ""

    var isValid: Bool {
        switch kind {
        case .orca: !agent.trimmingCharacters(in: .whitespaces).isEmpty
        case .script: !scriptPath.isEmpty
        }
    }

    func apply(to model: AppModel) async {
        let kind = kind, agent = agent.trimmingCharacters(in: .whitespaces), path = scriptPath
        await model.updateConfig { config in
            let id: LauncherID
            switch kind {
            case .orca:
                id = "orca"
                if let i = config.launchers.firstIndex(where: { $0.id == id }) {
                    var settings: [String: JSONValue] = [:]
                    if case .object(let existing) = config.launchers[i].settings { settings = existing }
                    settings["agent"] = .string(agent)
                    config.launchers[i].settings = .object(settings)
                } else {
                    config.launchers.append(LauncherConfig(id: id, type: OrcaLauncher.typeID, settings: .object(["agent": .string(agent)])))
                }
            case .script:
                id = "script"
                config.launchers.removeAll { $0.id == id }
                config.launchers.append(LauncherConfig(id: id, type: "script", settings: .object(["executable": .string(path)])))
            }
            for i in config.rules.indices where [Presets.reviewRequestedId, Presets.reviewReceivedId].contains(config.rules[i].id) {
                config.rules[i].launcherId = id
            }
        }
    }
}

extension AppModel {
    func toolIsOK(_ name: String) -> Bool {
        diagnostics.contains { $0.title == name && $0.level == .ok }
    }

    var orcaDetected: Bool {
        diagnostics.contains { $0.title.hasPrefix("orca") && $0.level == .ok } || PathResolver.find("orca", in: resolvedSearchPath) != nil
    }
}

private struct StepHeader: View {
    let title: LocalizedStringKey
    var body: some View { Text(title, bundle: .resources).font(.title2.bold()) }
}

private struct GitHubStep: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var verifying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "Welcome to Pilotboat")
            Text("Pilotboat watches GitHub for review requests and reviews on your pull requests, and starts an agent for each one. It only reads from GitHub, and it asks before starting anything.", bundle: .resources)
            if let login = model.githubLogin {
                Label { Text("Signed in as \(login)", bundle: .resources) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            } else {
                if PathResolver.find("gh", in: model.resolvedSearchPath) != nil {
                    Button(String(localized: "Use gh CLI", bundle: .resources)) { run { try await model.signInWithGhCLI() } }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(verifying)
                }
                HStack {
                    SecureField(String(localized: "Personal access token", bundle: .resources), text: $token).onSubmit(verify)
                    Button(String(localized: "Verify", bundle: .resources), action: verify)
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || verifying)
                }
                Text("Needs read access to repositories and pull requests. Classic token: repo scope. Fine-grained token: Pull requests (Read) and Metadata (Read).", bundle: .resources)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func verify() {
        let value = token
        run { try await model.signIn(token: value) }
    }

    private func run(_ body: @escaping () async throws -> String) {
        Task {
            verifying = true
            do { _ = try await body(); token = "" } catch { model.lastErrorMessage = error.localizedDescription }
            verifying = false
        }
    }
}

private struct LauncherStep: View {
    @Environment(AppModel.self) private var model
    let launcher: LauncherChoice
    @State private var importing = false
    @State private var checked = false

    // refreshDiagnostics stores the detail as "path — version".
    private var orcaVersion: String? {
        guard let item = model.diagnostics.first(where: { $0.title == "orca" && $0.level == .ok }),
              let version = item.detail?.components(separatedBy: " — ").last, !version.isEmpty else { return nil }
        return version
    }

    var body: some View {
        @Bindable var launcher = launcher
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "How should agents start?")
            Picker("", selection: $launcher.kind) {
                Text("Use Orca", bundle: .resources).tag(LauncherChoice.Kind.orca)
                Text("Use a script", bundle: .resources).tag(LauncherChoice.Kind.script)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if !checked {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…", bundle: .resources).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    switch launcher.kind {
                    case .orca:
                        if let version = orcaVersion {
                            Text("Orca \(version) detected", bundle: .resources).font(.caption).foregroundStyle(.secondary)
                        } else if model.orcaDetected {
                            Text("Orca detected", bundle: .resources).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Orca not found", bundle: .resources).font(.caption).foregroundStyle(.orange)
                        }
                        LabeledContent {
                            TextField(text: $launcher.agent) { Text("Agent", bundle: .resources) }.labelsHidden()
                        } label: {
                            Text("Agent", bundle: .resources)
                            Text("Orca agent id, for example claude or codex", bundle: .resources)
                        }
                    case .script:
                        HStack {
                            Text(launcher.scriptPath.isEmpty ? String(localized: "No file chosen", bundle: .resources) : launcher.scriptPath)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(String(localized: "Choose…", bundle: .resources)) { importing = true }
                        }
                        Text("A sample is included at contrib/launchers/git-worktree-terminal", bundle: .resources)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 22)
                Divider()
                ForEach(["git", "claude"], id: \.self) { tool in
                    let item = model.diagnostics.first { $0.title == tool }
                    let ok = model.toolIsOK(tool)
                    HStack(alignment: .firstTextBaseline) {
                        Label {
                            Text(verbatim: tool)
                        } icon: {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(ok ? .green : .red)
                        }
                        if ok {
                            if let detail = item?.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        } else {
                            Text("Not found. Install it, then check again", bundle: .resources).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(String(localized: "Check again", bundle: .resources)) { Task { await model.refreshDiagnostics() } }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { launcher.scriptPath = url.path }
        }
        .task {
            await model.refreshDiagnostics()
            launcher.kind = model.orcaDetected ? .orca : .script
            checked = true
        }
    }
}

private struct RepositoriesStep: View {
    @Environment(AppModel.self) private var model
    let launcher: LauncherChoice
    @State private var orcaRepos: [OrcaRepo] = []
    @State private var selected: Set<String> = []
    @State private var field = ""
    @State private var invalid = false

    private var available: [(repo: OrcaRepo, fullName: String)] {
        orcaRepos.compactMap { repo in
            guard let key = repo.canonicalKey, key.lowercased().hasPrefix("\(AppModel.host)/") else { return nil }
            let name = String(key.dropFirst(AppModel.host.count + 1))
            return model.config.repository(host: AppModel.host, fullName: name) == nil ? (repo, name) : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Which repositories?")
            if launcher.kind == .orca, !available.isEmpty {
                SectionCard("From Orca", trailing: {
                    Button(String(localized: "Add selected", bundle: .resources), action: addSelected).disabled(selected.isEmpty)
                }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(available, id: \.repo.id) { item in
                                Toggle(isOn: Binding(get: { selected.contains(item.repo.id) },
                                                     set: { if $0 { selected.insert(item.repo.id) } else { selected.remove(item.repo.id) } })) {
                                    VStack(alignment: .leading) {
                                        Text(item.fullName)
                                        Text(item.repo.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            HStack {
                TextField(String(localized: "owner/name", bundle: .resources), text: $field).onSubmit(addTyped)
                Button(String(localized: "Add", bundle: .resources), action: addTyped).disabled(field.isEmpty)
            }
            if invalid {
                Text("Use the form owner/name, for example cli/cli", bundle: .resources).font(.caption).foregroundStyle(.red)
            }
            SectionCard("Added") {
                if model.config.repositories.isEmpty {
                    Text("No repositories yet", bundle: .resources).foregroundStyle(.secondary)
                } else {
                    ChipList(items: model.config.repositories.map(\.fullName)) { name in
                        Task { await model.updateConfig { $0.repositories.removeAll { $0.fullName == name } } }
                    }
                }
            }
        }
        .task {
            guard launcher.kind == .orca else { return }
            do { orcaRepos = try await model.orcaRepos() } catch { model.lastErrorMessage = error.localizedDescription }
        }
    }

    private func addSelected() {
        let repos = available.filter { selected.contains($0.repo.id) }.map {
            Repository(fullName: $0.fullName, launcherBindings: ["orca": $0.repo.id])
        }
        selected = []
        Task { await model.updateConfig { $0.repositories.append(contentsOf: repos) } }
    }

    private func addTyped() {
        let name = field.trimmingCharacters(in: .whitespaces)
        let valid = name.wholeMatch(of: /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) != nil
        invalid = !valid
        guard valid else { return }
        field = ""
        guard model.config.repository(host: AppModel.host, fullName: name) == nil else { return }
        Task { await model.updateConfig { $0.repositories.append(Repository(fullName: name)) } }
    }
}

private struct AutomationsStep: View {
    @Environment(AppModel.self) private var model
    @Binding var includeExisting: Bool
    @State private var touched = false
    @State private var checking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Automations")
            ForEach([Presets.reviewRequestedId, Presets.reviewReceivedId], id: \.self) { id in
                if let rule = model.config.rule(id: id) {
                    SectionCard(LocalizedStringKey(rule.name), trailing: {
                        Toggle(rule.name, isOn: Binding(get: { rule.enabled }, set: { set(id, $0) }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }) {
                        Text(rule.eventKind.triggerDescription).font(.caption).foregroundStyle(.secondary)
                        if let template = model.config.promptTemplate(id: rule.promptTemplateId) {
                            DisclosureGroup(String(localized: "Instructions", bundle: .resources)) {
                                Text(template.body).font(.callout.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            let waiting = model.status.openReviewRequests.count
            Group {
                if checking {
                    HStack(spacing: 6) {
                        Text("Review requests already waiting:", bundle: .resources)
                        ProgressView().controlSize(.small)
                        Text("Checking…", bundle: .resources).foregroundStyle(.secondary)
                    }
                } else if waiting == 0 {
                    Text("Review requests already waiting: none", bundle: .resources)
                } else {
                    Text("Review requests already waiting: \(waiting)", bundle: .resources)
                }
            }
            Toggle(String(localized: "Handle them too", bundle: .resources), isOn: $includeExisting)
            Text("Off by default so that old requests do not all start at once", bundle: .resources)
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            if !touched {
                await model.updateConfig { config in
                    for i in config.rules.indices where [Presets.reviewRequestedId, Presets.reviewReceivedId].contains(config.rules[i].id) {
                        config.rules[i].enabled = true
                    }
                }
            }
            await model.pollOnce()
            checking = false
        }
    }

    private func set(_ id: String, _ on: Bool) {
        touched = true
        Task { await model.updateConfig { config in
            if let i = config.rules.firstIndex(where: { $0.id == id }) { config.rules[i].enabled = on }
        } }
    }
}
