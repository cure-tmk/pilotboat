import SwiftUI

struct AccountTab: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            if let login = model.githubLogin {
                Section {
                    LabeledContent(String(localized: "Signed in as", bundle: .resources), value: login)
                    scopes
                    Button(role: .destructive) { Task { await model.signOut() } } label: { Text("Sign out", bundle: .resources) }
                }
            } else {
                Section {
                    Button { run { try await model.signInWithGhCLI() } } label: { Text("Use gh CLI", bundle: .resources) }
                } footer: { Text("Uses the token from gh auth login", bundle: .resources) }
                Section {
                    SecureField(String(localized: "Personal access token", bundle: .resources), text: $token)
                    Button { run { try await model.signIn(token: token) } } label: { Text("Verify", bundle: .resources) }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    scopes
                }
                if busy { ProgressView().controlSize(.small) }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
    }

    private var scopes: some View {
        Text("Needs read access to repositories and pull requests. Classic token: repo scope. Fine-grained token: Pull requests (Read) and Metadata (Read).", bundle: .resources)
            .font(.caption).foregroundStyle(.secondary)
    }

    private func run(_ body: @escaping () async throws -> String) {
        busy = true; error = nil
        Task {
            do { _ = try await body(); token = "" } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
