import SwiftUI

/// Red-tinted message with a dismiss button; hidden while `message` is nil.
struct ErrorBanner: View {
    @Binding var message: String?

    var body: some View {
        if let text = message {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button { message = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Dismiss", bundle: .resources))
            }
            .padding(8)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
