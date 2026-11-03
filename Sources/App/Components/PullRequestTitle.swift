import Core
import SwiftUI

/// "repo #number" (bold) over the pull request title (secondary, one line).
struct PullRequestTitle: View {
    let name: String
    let title: String?

    init(ref: PullRequestRef) {
        name = "\(ref.repo.split(separator: "/").last.map(String.init) ?? ref.repo) #\(ref.number)"
        title = ref.title
    }

    init(run: Run) {
        name = run.shortTitle
        title = run.pullRequest?.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).bold()
            if let title { Text(title).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}
