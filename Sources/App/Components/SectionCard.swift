import SwiftUI

/// `GroupBox` with a headline title and an optional trailing control.
struct SectionCard<Content: View, Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            HStack {
                Text(title, bundle: .resources).font(.headline)
                Spacer()
                trailing()
            }
        }
    }
}
