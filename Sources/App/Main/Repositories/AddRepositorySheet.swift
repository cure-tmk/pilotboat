import Core
import LauncherOrca
import SwiftUI

struct AddRepositorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var orcaRepos: [OrcaRepo] = []
    @State private var picked: Set<String> = []

    private var orcaId: LauncherID? { model.config.launchers(ofType: OrcaLauncher.typeID).first?.id }

    private var candidates: [(repo: OrcaRepo, name: String)] {
        orcaRepos.compactMap { repo in
            guard let name = repo.fullName(host: Repository.defaultHost),
                  model.config.repository(host: Repository.defaultHost, fullName: name) == nil else { return nil }
            return (repo, name)
        }
    }

    private var typed: String { name.trimmingCharacters(in: .whitespaces) }
    private var typedValid: Bool { Repository.isValidFullName(typed) }
    private var typedTaken: Bool { model.config.repositories.contains { $0.fullName.caseInsensitiveCompare(typed) == .orderedSame } }

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "owner/name", bundle: .resources), text: $name)
                if !typed.isEmpty, !typedValid {
                    Text("Use the form owner/name", bundle: .resources).font(.caption).foregroundStyle(.red)
                } else if typedTaken {
                    Text("Already added", bundle: .resources).font(.caption).foregroundStyle(.red)
                }
            }
            if !candidates.isEmpty {
                Section {
                    ForEach(candidates, id: \.repo.id) { candidate in
                        Toggle(candidate.name, isOn: Binding(
                            get: { picked.contains(candidate.repo.id) },
                            set: { if $0 { picked.insert(candidate.repo.id) } else { picked.remove(candidate.repo.id) } }))
                    }
                } header: { Text("From Orca", bundle: .resources) }
            }
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { Text("Cancel", bundle: .resources) }.keyboardShortcut(.cancelAction)
                Button { add() } label: { Text("Add", bundle: .resources) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(typedValid && !typedTaken) && picked.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 380)
        .task {
            guard let orcaId else { return }
            orcaRepos = (try? await model.orca.repos(launcherId: orcaId)) ?? []
        }
    }

    private func add() {
        var new: [Repository] = candidates.filter { picked.contains($0.repo.id) }
            .map { candidate in Repository(fullName: candidate.name, launcherBindings: orcaId.map { [$0: candidate.repo.id] } ?? [:]) }
        if typedValid, !typedTaken, !new.contains(where: { $0.fullName.caseInsensitiveCompare(typed) == .orderedSame }) {
            new.append(Repository(fullName: typed))
        }
        let added = new
        model.edit { $0.repositories.append(contentsOf: added) }
        if let first = added.first { model.router.repositoryId = first.id }
        dismiss()
    }
}
