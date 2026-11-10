import SwiftUI

struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section { SignInForm { dismiss() } }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("Cancel", bundle: .resources) } } }
    }
}
