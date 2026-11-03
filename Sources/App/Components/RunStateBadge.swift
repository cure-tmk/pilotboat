import Core
import SwiftUI

/// State label + symbol in the state's color. Use `.labelStyle(.iconOnly)` for the compact form.
struct RunStateBadge: View {
    let run: Run

    var body: some View {
        Label(run.stateLabel, systemImage: run.state.symbol)
            .foregroundStyle(run.state.color)
    }
}
