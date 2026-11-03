import Core
import SwiftUI

/// Compact run row: state icon, "repo #number", state, relative time.
/// `showsDetails` adds the pull request title and automation name (Activity list).
struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: Run
    var showsDetails = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RunStateBadge(run: run).labelStyle(.iconOnly)
            VStack(alignment: .leading, spacing: 2) {
                if showsDetails {
                    PullRequestTitle(run: run)
                    Text(model.config.rule(id: run.ruleId)?.name ?? run.ruleId)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(run.shortTitle) · \(run.stateLabel)").lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            RelativeDate(date: run.updatedAt).font(.caption).foregroundStyle(.secondary)
        }
    }
}
