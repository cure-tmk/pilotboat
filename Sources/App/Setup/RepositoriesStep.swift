import Core
import LauncherOrca
import SwiftUI

struct RepositoriesStep: View {
    @Environment(AppModel.self) private var model
    let launcher: LauncherChoice
    @State private var orcaRepos: [OrcaRepo] = []
    @State private var loadError: String?
    @State private var selected: Set<String> = []
    @State private var field = ""
    @State private var invalid = false

    private var orcaId: LauncherID? { model.config.launchers(ofType: OrcaLauncher.typeID).first?.id }

    private var available: [(repo: OrcaRepo, fullName: String)] {
        orcaRepos.compactMap { repo in
            guard let name = repo.fullName(host: Repository.defaultHost),
                  model.config.repository(host: Repository.defaultHost, fullName: name) == nil else { return nil }
            return (repo, name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Which repositories?")
            if launcher.kind == .orca, !available.isEmpty { fromOrca }
            if let loadError { Text(loadError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
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
                        guard let id = model.config.repositories.first(where: { $0.fullName == name })?.id else { return }
                        model.edit { $0.removeRepository(id: id) }
                    }
                }
            }
        }
        .task {
            guard launcher.kind == .orca, let orcaId else { return }
            do { orcaRepos = try await model.orca.repos(launcherId: orcaId) } catch { loadError = error.localizedDescription }
        }
    }

    private var fromOrca: some View {
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

    private func addSelected() {
        guard let orcaId else { return }
        let repos = available.filter { selected.contains($0.repo.id) }.map {
            Repository(fullName: $0.fullName, launcherBindings: [orcaId: $0.repo.id])
        }
        selected = []
        model.edit { $0.repositories.append(contentsOf: repos) }
    }

    private func addTyped() {
        let name = field.trimmingCharacters(in: .whitespaces)
        invalid = !Repository.isValidFullName(name)
        guard !invalid else { return }
        field = ""
        guard model.config.repository(host: Repository.defaultHost, fullName: name) == nil else { return }
        let repo = Repository(fullName: name)
        model.edit { $0.repositories.append(repo) }
    }
}
