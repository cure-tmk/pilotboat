import SwiftUI

/// Title with a secondary one-line explanation underneath.
struct Captioned: View {
    let title: LocalizedStringKey
    let caption: LocalizedStringKey

    init(_ title: LocalizedStringKey, caption: LocalizedStringKey) {
        self.title = title; self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title, bundle: .resources)
            Text(caption, bundle: .resources).font(.caption).foregroundStyle(.secondary)
        }
    }
}
