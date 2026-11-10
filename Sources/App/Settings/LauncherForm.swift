import Core
import LauncherOrca
import LauncherScript
import SwiftUI

struct LauncherForm: View {
    @Environment(AppModel.self) private var model
    let launcher: LauncherConfig
    @State private var diagnostics: [DiagnosticItem] = []

    var body: some View {
        Form {
            if launcher.type == OrcaLauncher.typeID {
                OrcaLauncherFields(launcher: launcher)
            } else {
                ScriptLauncherFields(launcher: launcher)
            }
            Section {
                Button { test() } label: { Text("Test", bundle: .resources) }
                ForEach(Array(diagnostics.enumerated()), id: \.offset) { DiagnosticRow(item: $1) }
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        diagnostics = []
        let launcher = launcher
        Task { diagnostics = await model.diagnose(launcher) }
    }
}

extension AppModel {
    /// Replaces the keys `old` encoded with those `new` encodes, keeping keys the typed settings do not know.
    func setLauncherSettings(_ id: LauncherID, replacing old: JSONValue, with new: JSONValue) {
        edit { config in
            guard let i = config.launchers.firstIndex(where: { $0.id == id }) else { return }
            var merged = config.launchers[i].settings.object ?? [:]
            for k in (old.object ?? [:]).keys { merged[k] = nil }
            for (k, v) in new.object ?? [:] { merged[k] = v }
            config.launchers[i].settings = .object(merged)
        }
    }
}

private struct UnreadableSettingsWarning: View {
    var body: some View {
        Label {
            Text("These settings could not be read; fix config.json or re-create the launcher", bundle: .resources)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private func optional(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

private struct OrcaLauncherFields: View {
    @Environment(AppModel.self) private var model
    let launcher: LauncherConfig
    @State private var settings = OrcaSettings(agent: "")
    @State private var unreadable = false

    var body: some View {
        Section {
            if unreadable { UnreadableSettingsWarning() }
            CommitField(title: String(localized: "Agent", bundle: .resources), value: settings.agent) { v in update { $0.agent = v } }
            CommitField(title: String(localized: "Model", bundle: .resources), value: settings.model ?? "") { v in update { $0.model = optional(v) } }
            CommitField(title: String(localized: "Effort (optional)", bundle: .resources), value: settings.effort ?? "") { v in
                update { $0.effort = optional(v) }
            }
            HStack {
                CommitField(title: String(localized: "orca path (optional)", bundle: .resources), value: settings.orcaPath ?? "") { v in
                    update { $0.orcaPath = optional(v) }
                }
                Button { if let url = Panel.open() { update { $0.orcaPath = url.path } } } label: { Text("Browse…", bundle: .resources) }
            }
        }
        Section {
            hook(\.setupForReview, Text("For other people's pull requests", bundle: .resources))
            hook(\.setupForOwnPR, Text("For my pull requests", bundle: .resources))
            Toggle(isOn: Binding(get: { settings.activate }, set: { v in update { $0.activate = v } })) {
                Text("Show the worktree in Orca", bundle: .resources)
            }
        }
        .onChange(of: launcher.settings, initial: true) {
            do { settings = try OrcaSettings(json: launcher.settings); unreadable = false } catch { unreadable = true }
        }
    }

    private func hook(_ keyPath: WritableKeyPath<OrcaSettings, SetupHook>, _ label: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(selection: Binding(get: { settings[keyPath: keyPath] }, set: { v in update { $0[keyPath: keyPath] = v } })) {
                ForEach(SetupHook.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: { label }
            Text(settings[keyPath: keyPath].caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func update(_ change: (inout OrcaSettings) -> Void) {
        let old = try? settings.json()
        change(&settings)
        guard !unreadable, let old, let new = try? settings.json() else { return }
        model.setLauncherSettings(launcher.id, replacing: old, with: new)
    }
}

private extension SetupHook {
    var label: String {
        switch self {
        case .skip: String(localized: "Skip", bundle: .resources)
        case .inherit: String(localized: "Inherit", bundle: .resources)
        case .run: String(localized: "Run", bundle: .resources)
        }
    }

    var caption: String {
        switch self {
        case .skip: String(localized: "Do not run the repository's setup script", bundle: .resources)
        case .inherit: String(localized: "Follow the repository's own setting in Orca", bundle: .resources)
        case .run: String(localized: "Always run the repository's setup script", bundle: .resources)
        }
    }
}

private struct ScriptLauncherFields: View {
    @Environment(AppModel.self) private var model
    let launcher: LauncherConfig
    @State private var settings = ScriptSettings()
    @State private var capabilities: LauncherCapabilities?
    @State private var unreadable = false

    var body: some View {
        Section {
            if unreadable { UnreadableSettingsWarning() }
            HStack {
                CommitField(title: String(localized: "Executable", bundle: .resources), value: settings.executable ?? "") { v in
                    update { $0.executable = optional(v) }
                }
                Button { if let url = Panel.open() { update { $0.executable = url.path } } } label: { Text("Browse…", bundle: .resources) }
            }
            HStack {
                CommitField(title: String(localized: "Default local path", bundle: .resources), value: settings.localPath ?? "") { v in
                    update { $0.localPath = optional(v) }
                }
                Button { if let url = Panel.open(directories: true) { update { $0.localPath = url.path } } } label: { Text("Browse…", bundle: .resources) }
            }
            if let capabilities {
                LabeledContent(String(localized: "Capabilities", bundle: .resources)) { Text(Self.describe(capabilities)) }
            }
        }
        .onChange(of: launcher.settings, initial: true) {
            do { settings = try launcher.settings.decode(ScriptSettings.self); unreadable = false } catch { unreadable = true }
        }
        .task(id: settings.executable) {
            let launcher = launcher
            capabilities = settings.executable == nil ? nil : await model.capabilities(of: launcher)
        }
    }

    private static func describe(_ capabilities: LauncherCapabilities) -> String {
        guard !capabilities.isEmpty else { return String(localized: "None reported", bundle: .resources) }
        return [capabilities.contains(.reuseWorkspace) ? String(localized: "Reuses worktrees", bundle: .resources) : nil,
                capabilities.contains(.sendToSession) ? String(localized: "Sends to a running session", bundle: .resources) : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func update(_ change: (inout ScriptSettings) -> Void) {
        let old = settings.json()
        change(&settings)
        guard !unreadable else { return }
        model.setLauncherSettings(launcher.id, replacing: old, with: settings.json())
    }
}
