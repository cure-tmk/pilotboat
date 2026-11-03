import Core
import Persistence
import SwiftUI
import UniformTypeIdentifiers

struct DataTab: View {
    @Environment(AppModel.self) private var model
    @State private var pendingImport: URL?
    @State private var summary: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button { export() } label: { Text("Export…", bundle: .resources) }
                } label: {
                    Text("Export settings", bundle: .resources)
                    Text("Automations, instructions and repository names. Tokens, Orca links and script executables are never included.", bundle: .resources)
                }
                LabeledContent {
                    Button { chooseImport() } label: { Text("Import…", bundle: .resources) }
                } label: {
                    Text("Import settings", bundle: .resources)
                    Text("Merges into your current settings. You choose how to handle conflicts.", bundle: .resources)
                }
            }
            Section {
                LabeledContent {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory]) } label: { Text("Reveal", bundle: .resources) }
                } label: {
                    Text("Configuration folder", bundle: .resources)
                    Text(AppPaths.supportDirectory.path).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import settings", bundle: .resources).font(.headline)
                Text("Automations and instructions that already exist here can be overwritten, or both versions can be kept", bundle: .resources)
                HStack {
                    Spacer()
                    Button(role: .cancel) { pendingImport = nil } label: { Text("Cancel", bundle: .resources) }.keyboardShortcut(.cancelAction)
                    Button { runImport(.rename) } label: { Text("Keep both", bundle: .resources) }
                    Button { runImport(.overwrite) } label: { Text("Overwrite", bundle: .resources) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
        .alert(String(localized: "Import settings", bundle: .resources), isPresented: Binding(get: { summary != nil }, set: { if !$0 { summary = nil } })) {
            Button(String(localized: "OK", bundle: .resources)) {}
        } message: { Text(summary ?? "") }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pilotboat-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportConfig(to: url) }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK { pendingImport = panel.url }
    }

    private func runImport(_ policy: ImportConflictPolicy) {
        guard let url = pendingImport else { return }
        pendingImport = nil
        Task {
            do {
                let result = try await model.importConfig(from: url, policy: policy)
                var lines = [String(localized: "Settings imported", bundle: .resources)]
                let names = Set(result.conflicts.map { id in result.config.rule(id: id)?.name ?? result.config.promptTemplate(id: id)?.name ?? id }).sorted()
                if !names.isEmpty {
                    let how = policy == .overwrite ? String(localized: "Overwritten", bundle: .resources) : String(localized: "Kept both", bundle: .resources)
                    lines.append("\(how): \(names.joined(separator: ", "))")
                }
                if !result.launchersNeedingExecutable.isEmpty {
                    lines.append(String(localized: "Choose an executable in Launchers for: \(result.launchersNeedingExecutable.joined(separator: ", "))", bundle: .resources))
                }
                summary = lines.joined(separator: "\n")
            } catch { summary = error.localizedDescription }
        }
    }
}
