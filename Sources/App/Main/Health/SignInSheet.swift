import SwiftUI

struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Button { run { try await model.signInWithGhCLI() } } label: { Text("Use gh CLI", bundle: .resources) }.buttonStyle(.borderedProminent)
            }
            Section {
                SecureField(text: $token) { Text("Token", bundle: .resources) }
                Button { run { try await model.signIn(token: token) } } label: { Text("Sign in", bundle: .resources) }.disabled(token.isEmpty)
            } header: {
                Text("Personal access token", bundle: .resources)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .frame(width: 420)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("Cancel", bundle: .resources) } } }
    }

    private func run(_ body: @escaping () async throws -> String) {
        busy = true; error = nil
        Task {
            do { _ = try await body(); dismiss() } catch { self.error = AppModel.describe(error) }
            busy = false
        }
    }
}
