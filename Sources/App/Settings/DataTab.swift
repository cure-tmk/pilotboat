import Core
import Persistence
import SwiftUI
import UniformTypeIdentifiers

struct DataTab: View {
    @Environment(AppModel.self) private var model
    @State private var pendingImport: PendingImport?
    @State private var summary: ImportSummary?

    private struct PendingImport: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private struct ImportSummary: Identifiable {
        let text: String
        var id: String { text }
    }

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
        .sheet(item: $pendingImport) { pending in
            VStack(alignment: .leading, spacing: 16) {
                Text("Import settings", bundle: .resources).font(.headline)
                Text("Automations and instructions that already exist here can be overwritten, or both versions can be kept", bundle: .resources)
                HStack {
                    Spacer()
                    Button(role: .cancel) { pendingImport = nil } label: { Text("Cancel", bundle: .resources) }.keyboardShortcut(.cancelAction)
                    Button { runImport(pending.url, .rename) } label: { Text("Keep both", bundle: .resources) }
                    Button { runImport(pending.url, .overwrite) } label: { Text("Overwrite", bundle: .resources) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
        .alert(String(localized: "Import settings", bundle: .resources), isPresented: Binding(get: { summary != nil }, set: { if !$0 { summary = nil } }),
               presenting: summary) { _ in
            Button(String(localized: "OK", bundle: .resources)) {}
        } message: { Text($0.text) }
    }

    private func export() {
        guard let url = Panel.save(name: "pilotboat-settings.json", types: [.json]) else { return }
        Task { await model.exportConfig(to: url) }
    }

    private func chooseImport() {
        pendingImport = Panel.open(types: [.json]).map(PendingImport.init)
    }

    private func runImport(_ url: URL, _ policy: ImportConflictPolicy) {
        pendingImport = nil
        Task {
            do {
                guard let result = try await model.importConfig(from: url, policy: policy) else { return }
                var lines = [String(localized: "Settings imported", bundle: .resources)]
                let names = Set(result.conflicts.map { id in result.config.rule(id: id)?.name ?? result.config.promptTemplate(id: id)?.name ?? id }).sorted()
                if !names.isEmpty {
                    let how = policy == .overwrite ? String(localized: "Overwritten", bundle: .resources) : String(localized: "Kept both", bundle: .resources)
                    lines.append("\(how): \(names.joined(separator: ", "))")
                }
                if !result.launchersNeedingExecutable.isEmpty {
                    lines.append(String(localized: "Choose an executable in Launchers for: \(result.launchersNeedingExecutable.joined(separator: ", "))", bundle: .resources))
                }
                summary = ImportSummary(text: lines.joined(separator: "\n"))
            } catch { summary = ImportSummary(text: error.localizedDescription) }
        }
    }
}
