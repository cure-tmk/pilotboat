import Core
import LauncherOrca
import LauncherScript
import SwiftUI

struct LaunchersTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: LauncherID?
    @State private var blockedBy: [String]?
    @State private var confirmDelete = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.config.launchers, selection: $selection) { launcher in
                    Label(launcher.id, systemImage: launcher.type == OrcaLauncher.typeID ? "ferry" : "terminal").tag(launcher.id)
                }
                Divider()
                HStack {
                    Menu {
                        Button(String(localized: "Orca", bundle: .resources)) { add(OrcaLauncher.typeID) }
                        Button(String(localized: "Script", bundle: .resources)) { add(ScriptLauncher.typeID) }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel(Text("Add launcher", bundle: .resources))
                    Button { remove() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless).disabled(selection == nil)
                        .accessibilityLabel(Text("Delete launcher", bundle: .resources))
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 280, maxHeight: .infinity)
            Group {
                if let id = selection, let launcher = model.config.launcher(id: id) {
                    LauncherForm(launcher: launcher).id(id)
                } else {
                    ContentUnavailableView(String(localized: "Select a launcher", bundle: .resources), systemImage: "terminal")
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(String(localized: "Delete this launcher?", bundle: .resources), isPresented: $confirmDelete) {
            Button(String(localized: "Delete launcher", bundle: .resources), role: .destructive) { delete() }
        }
        .alert(String(localized: "This launcher is in use", bundle: .resources), isPresented: Binding(get: { blockedBy != nil }, set: { if !$0 { blockedBy = nil } })) {
            Button(String(localized: "OK", bundle: .resources)) {}
        } message: {
            Text("Used by: \((blockedBy ?? []).joined(separator: ", ")). Change those automations first", bundle: .resources)
        }
    }

    private func add(_ type: String) {
        var id = type, n = 2
        while model.config.launcher(id: id) != nil { id = "\(type)-\(n)"; n += 1 }
        let settings: JSONValue = type == OrcaLauncher.typeID
            ? .object(["agent": .string("claude"), "setupForReview": .string("skip"), "setupForOwnPR": .string("inherit"), "activate": .bool(false)])
            : .object([:])
        let launcher = LauncherConfig(id: id, type: type, settings: settings)
        selection = id
        Task { await model.updateConfig { $0.launchers.append(launcher) } }
    }

    private func remove() {
        guard let id = selection else { return }
        let users = model.config.rules.filter { $0.launcherId == id }.map(\.name)
        if users.isEmpty { confirmDelete = true } else { blockedBy = users }
    }

    private func delete() {
        guard let id = selection else { return }
        selection = nil
        Task {
            await model.updateConfig { config in
                config.launchers.removeAll { $0.id == id }
                for i in config.repositories.indices { config.repositories[i].launcherBindings[id] = nil }
            }
        }
    }
}

private struct LauncherForm: View {
    @Environment(AppModel.self) private var model
    let launcher: LauncherConfig
    @State private var diagnostics: [DiagnosticItem]?
    @State private var capabilities: LauncherCapabilities?

    private var isOrca: Bool { launcher.type == OrcaLauncher.typeID }

    private func text(_ key: String, _ title: String) -> some View {
        CommitField(title: title, value: launcher.settings.text(key)) { value in update { $0.set(key, text: value) } }
    }

    private func update(_ change: @escaping @Sendable (inout JSONValue) -> Void) {
        let id = launcher.id
        Task {
            await model.updateConfig { config in
                if let i = config.launchers.firstIndex(where: { $0.id == id }) { change(&config.launchers[i].settings) }
            }
        }
    }

    private func browse(_ key: String, directories: Bool = false) -> some View {
        Button { if let path = chooseFile(directories: directories) { update { $0.set(key, text: path) } } } label: { Text("Browse…", bundle: .resources) }
    }

    private func hook(_ key: String, _ label: LocalizedStringKey) -> some View {
        let value = launcher.settings.text(key)
        let caption = switch value {
        case "run": "Always run the repository's setup script"
        case "inherit": "Follow the repository's own setting in Orca"
        default: "Do not run the repository's setup script"
        }
        return VStack(alignment: .leading, spacing: 2) {
            Picker(selection: Binding(get: { value }, set: { v in update { $0.set(key, text: v) } })) {
                Text("Skip", bundle: .resources).tag("skip")
                Text("Inherit", bundle: .resources).tag("inherit")
                Text("Run", bundle: .resources).tag("run")
            } label: { Text(label, bundle: .resources) }
            Text(LocalizedStringKey(caption), bundle: .resources).font(.caption).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        Form {
            if isOrca {
                Section {
                    text("agent", String(localized: "Agent", bundle: .resources))
                    text("model", String(localized: "Model", bundle: .resources))
                    text("effort", String(localized: "Effort (optional)", bundle: .resources))
                    HStack { text("orcaPath", String(localized: "orca path (optional)", bundle: .resources)); browse("orcaPath") }
                }
                Section {
                    hook("setupForReview", "For other people's pull requests")
                    hook("setupForOwnPR", "For my pull requests")
                    Toggle(isOn: Binding(get: { launcher.settings.flag("activate") }, set: { v in update { $0.set("activate", flag: v) } })) {
                        Text("Show the worktree in Orca", bundle: .resources)
                    }
                }
            } else {
                Section {
                    HStack { text("executable", String(localized: "Executable", bundle: .resources)); browse("executable") }
                    HStack { text("localPath", String(localized: "Default local path", bundle: .resources)); browse("localPath", directories: true) }
                    if let capabilities {
                        LabeledContent(String(localized: "Capabilities", bundle: .resources)) {
                            Text(capabilities.isEmpty ? String(localized: "None reported", bundle: .resources)
                                 : [capabilities.contains(.reuseWorkspace) ? String(localized: "Reuses worktrees", bundle: .resources) : nil,
                                    capabilities.contains(.sendToSession) ? String(localized: "Sends to a running session", bundle: .resources) : nil]
                                    .compactMap { $0 }.joined(separator: ", "))
                        }
                    }
                }
            }
            Section {
                Button { test() } label: { Text("Test", bundle: .resources) }
                ForEach(Array((diagnostics ?? []).enumerated()), id: \.offset) { _, item in
                    Label {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        switch item.level {
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: launcher.settings.text("executable")) {
            let exe = launcher.settings.text("executable")
            capabilities = isOrca || exe.isEmpty ? nil : await model.scriptLauncher.capabilities(executable: exe)
        }
    }

    private func test() {
        diagnostics = []
        Task {
            diagnostics = isOrca ? await model.orcaLauncher.diagnose(settings: launcher.settings)
                                 : await model.scriptLauncher.diagnose(settings: launcher.settings)
        }
    }
}
