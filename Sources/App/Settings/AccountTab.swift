import SwiftUI

struct AccountTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if let login = model.account.login {
                    LabeledContent(String(localized: "Signed in as", bundle: .resources), value: login)
                    Button(role: .destructive) { Task { await model.account.signOut() } } label: { Text("Sign out", bundle: .resources) }
                } else {
                    SignInForm()
                }
            }
        }
        .formStyle(.grouped)
    }
}
