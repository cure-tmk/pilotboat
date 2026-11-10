import Core
import LauncherOrca
import LauncherScript
import SwiftUI

struct LaunchersTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: LauncherID?
    @State private var blocked: Blocked?
    @State private var confirmDelete = false

    private struct Blocked: Identifiable {
        let names: [String]
        var id: [String] { names }
    }

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
        .alert(String(localized: "This launcher is in use", bundle: .resources),
               isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } }), presenting: blocked) { _ in
            Button(String(localized: "OK", bundle: .resources)) {}
        } message: {
            Text("Used by: \($0.names.joined(separator: ", ")). Change those automations first", bundle: .resources)
        }
    }

    private func add(_ type: String) {
        let settings = type == OrcaLauncher.typeID ? (try? OrcaSettings(agent: "claude").json()) ?? .object([:]) : .object([:])
        var preview = model.config
        let id = preview.addLauncher(type: type, settings: settings)
        model.edit { $0.addLauncher(id: id, type: type, settings: settings) }
        selection = id
    }

    private func remove() {
        guard let id = selection else { return }
        var check = model.config
        do {
            try check.removeLauncher(id: id)
            confirmDelete = true
        } catch ConfigEditError.launcherInUse(let names) {
            blocked = Blocked(names: names)
        } catch {
            model.report(error)
        }
    }

    private func delete() {
        guard let id = selection else { return }
        selection = nil
        model.edit { try? $0.removeLauncher(id: id) }
    }
}
