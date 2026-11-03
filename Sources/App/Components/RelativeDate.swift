import SwiftUI

/// "2 minutes ago", updating live. `body` is a `Text` so it can be interpolated into other `Text`s.
struct RelativeDate: View {
    let date: Date

    var body: Text {
        Text("\(Text(date, style: .relative)) ago", bundle: .resources)
    }
}
