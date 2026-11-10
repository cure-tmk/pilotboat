import SwiftUI

/// `GroupBox` with a headline title and an optional trailing control.
struct SectionCard<Content: View, Trailing: View>: View {
    let title: Text
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = Text(title, bundle: .resources); self.trailing = trailing; self.content = content
    }

    init(verbatim title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = Text(verbatim: title); self.trailing = trailing; self.content = content
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            HStack {
                title.font(.headline)
                Spacer()
                trailing()
            }
        }
    }
}
