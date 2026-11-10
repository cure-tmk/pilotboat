import SwiftUI

/// GitHub sign-in: gh CLI when available, otherwise or alternatively a personal access token.
struct SignInForm: View {
    @Environment(AppModel.self) private var model
    var onSignedIn: () -> Void = {}
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.account.ghAvailable {
                Button { run { try await model.account.signInWithGhCLI() } } label: { Text("Use gh CLI", bundle: .resources) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            HStack {
                SecureField(String(localized: "Personal access token", bundle: .resources), text: $token).onSubmit(verify)
                Button(action: verify) { Text("Verify", bundle: .resources) }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                if busy { ProgressView().controlSize(.small) }
            }
            Text("Needs read access to repositories and pull requests. Classic token: repo scope. Fine-grained token: Pull requests (Read) and Metadata (Read).", bundle: .resources)
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .disabled(busy)
    }

    private func verify() {
        let value = token
        run { try await model.account.signIn(token: value) }
    }

    private func run(_ body: @escaping @MainActor () async throws -> String) {
        busy = true
        error = nil
        Task {
            do {
                _ = try await body()
                token = ""
                onSignedIn()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
