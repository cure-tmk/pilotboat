import SwiftUI

struct LauncherStep: View {
    @Environment(AppModel.self) private var model
    let launcher: LauncherChoice
    @State private var checked = false

    private var orca: ToolCheck? { model.health.tool("orca") }

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
                    case .orca: orcaFields(agent: $launcher.agent)
                    case .script: scriptFields
                    }
                }
                .padding(.leading, 22)
                Divider()
                ForEach(["git", "claude"], id: \.self) { name in
                    DiagnosticRow(item: (model.health.tool(name) ?? ToolCheck(name: name)).item)
                }
                Button(String(localized: "Check again", bundle: .resources)) { Task { await model.refreshDiagnostics() } }
            }
        }
        .task {
            await model.refreshDiagnostics()
            launcher.kind = orca?.path != nil ? .orca : .script
            checked = true
        }
    }

    @ViewBuilder private func orcaFields(agent: Binding<String>) -> some View {
        if let version = orca?.version {
            Text("Orca \(version) detected", bundle: .resources).font(.caption).foregroundStyle(.secondary)
        } else if orca?.path != nil {
            Text("Orca detected", bundle: .resources).font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Orca not found", bundle: .resources).font(.caption).foregroundStyle(.orange)
        }
        LabeledContent {
            TextField(text: agent) { Text("Agent", bundle: .resources) }.labelsHidden()
        } label: {
            Text("Agent", bundle: .resources)
            Text("Orca agent id, for example claude or codex", bundle: .resources)
        }
    }

    @ViewBuilder private var scriptFields: some View {
        HStack {
            Text(launcher.scriptPath.isEmpty ? String(localized: "No file chosen", bundle: .resources) : launcher.scriptPath)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(String(localized: "Choose…", bundle: .resources)) {
                if let url = Panel.open() { launcher.scriptPath = url.path }
            }
        }
        Text("A sample is included at contrib/launchers/git-worktree-terminal", bundle: .resources)
            .font(.caption).foregroundStyle(.secondary)
    }
}
