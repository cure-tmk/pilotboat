import SwiftUI

struct GitHubStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "Welcome to Pilotboat")
            Text("Pilotboat watches GitHub for review requests and reviews on your pull requests, and starts an agent for each one. It only reads from GitHub. Each automation can ask you first or run automatically.", bundle: .resources)
            if let login = model.account.login {
                Label { Text("Signed in as \(login)", bundle: .resources) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            } else {
                SignInForm()
            }
        }
    }
}
