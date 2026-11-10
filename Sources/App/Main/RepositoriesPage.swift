import Core
import LauncherOrca
import SwiftUI

struct RepositoriesPage: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var confirmRemove = false

    private var selected: Repository? { model.router.repositoryId.flatMap { model.config.repository(id: $0) } }

    var body: some View {
        @Bindable var router = model.router
        HSplitView {
            List(model.config.repositories, selection: $router.repositoryId) { repo in
                HStack {
                    Toggle(isOn: Binding(get: { repo.monitoring }, set: { on in update(repo.id) { $0.monitoring = on } })) { EmptyView() }
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.fullName)
                        Text(linked(repo) ? "Linked to Orca" : "Not linked", bundle: .resources).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .tag(repo.id)
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
            Group {
                if let repo = selected {
                    RepositoryDetail(repo: repo).id(repo.id)
                } else {
                    ContentUnavailableView(String(localized: "Select a repository", bundle: .resources), systemImage: "folder")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup {
                Button { adding = true } label: { Label(String(localized: "Add repository", bundle: .resources), systemImage: "plus") }
                Button { confirmRemove = true } label: { Label(String(localized: "Remove repository", bundle: .resources), systemImage: "minus") }
                    .disabled(selected == nil)
            }
        }
        .sheet(isPresented: $adding) { AddRepositorySheet() }
        .confirmationDialog(String(localized: "Remove \(selected?.fullName ?? "")?", bundle: .resources), isPresented: $confirmRemove) {
            Button(String(localized: "Remove repository", bundle: .resources), role: .destructive) { remove() }
        } message: {
            Text("Automations limited to this repository will no longer apply to it", bundle: .resources)
        }
    }

    private func linked(_ repo: Repository) -> Bool {
        model.config.launchers(ofType: OrcaLauncher.typeID).contains { repo.launcherBindings[$0.id] != nil }
    }

    private func update(_ id: UUID, _ change: @escaping @Sendable (inout Repository) -> Void) {
        model.edit { config in if let i = config.repositories.firstIndex(where: { $0.id == id }) { change(&config.repositories[i]) } }
    }

    private func remove() {
        guard let id = selected?.id else { return }
        model.router.repositoryId = nil
        model.edit { $0.removeRepository(id: id) }
    }
}
