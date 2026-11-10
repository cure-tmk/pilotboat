import Core
import SwiftUI

/// Level icon, title and selectable detail for one diagnostic.
struct DiagnosticRow: View {
    let item: DiagnosticItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } icon: {
            switch item.level {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }
}
