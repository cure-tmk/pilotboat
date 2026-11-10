import Core
import SwiftUI

struct RunDetail: View {
    @Environment(AppModel.self) private var model
    let run: Run
    @State private var events: [Event] = []
    @State private var promptExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                actions
                trigger
                instructions
                result
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: run) { events = (try? await model.eventsForRun(id: run.id)) ?? [] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.pullRequest?.title ?? run.shortTitle).font(.title2).bold().textSelection(.enabled)
            Text("\(run.shortTitle)\(run.pullRequest.map { " · \($0.headRef)" } ?? "")").foregroundStyle(.secondary)
            HStack {
                RunStateBadge(run: run)
                Text(run.updatedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack {
            switch run.state {
            case .pendingApproval:
                Button { Task { await model.skip(runId: run.id) } } label: { Text("Skip", bundle: .resources) }
                Button { Task { await model.approve(runId: run.id) } } label: { Text("Run", bundle: .resources) }.buttonStyle(.borderedProminent)
            case .failed:
                Button { Task { await model.retry(runId: run.id) } } label: { Text("Retry", bundle: .resources) }
            case .launched where run.workspaceRef != nil:
                Button { Task { await model.openWorkspace(runId: run.id) } } label: { Text("Open worktree", bundle: .resources) }
            default: EmptyView()
            }
            Button { model.openPR(run: run) } label: { Text("Open on GitHub", bundle: .resources) }
        }
    }

    private var trigger: some View {
        SectionCard("What triggered it") {
            if events.isEmpty {
                Text("No events recorded", bundle: .resources).foregroundStyle(.secondary)
            }
            if let summary = events.reviewSummary {
                line(Text("\(summary.count) reviews from \(summary.reviewers.formatted())", bundle: .resources), date: summary.last)
            }
            ForEach(Array(events.filter { $0.kind != .reviewSubmitted }.enumerated()), id: \.offset) { _, event in
                HStack {
                    Text(event.kind.shortName)
                    if let actor = event.actor {
                        Text(actor.login).foregroundStyle(.secondary)
                        if actor.isBot { Chip(text: "bot") }
                    }
                    Spacer()
                    RelativeDate(date: event.occurredAt).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func line(_ text: Text, date: Date) -> some View {
        HStack {
            text
            Spacer()
            RelativeDate(date: date).foregroundStyle(.secondary)
        }
    }

    private var instructions: some View {
        SectionCard("Instructions sent to the agent") {
            if let prompt = run.snapshot?.renderedPrompt {
                Text(prompt)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(promptExpanded ? nil : 8)
                    .textSelection(.enabled)
                if prompt.split(separator: "\n", omittingEmptySubsequences: false).count > 8 {
                    Button { promptExpanded.toggle() } label: { promptExpanded ? Text("Show less", bundle: .resources) : Text("Show more", bundle: .resources) }
                        .buttonStyle(.link)
                }
            } else {
                Text("Not rendered yet", bundle: .resources).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var result: some View {
        if run.error != nil || run.workspaceRef != nil || run.terminalHandle != nil {
            SectionCard("Result") {
                if let error = run.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if let ref = run.workspaceRef {
                    LabeledContent { Text(ref).textSelection(.enabled) } label: { Text("Worktree", bundle: .resources) }
                }
                if let handle = run.terminalHandle {
                    LabeledContent { Text(handle).textSelection(.enabled) } label: { Text("Terminal", bundle: .resources) }
                }
            }
        }
    }
}

struct ReviewSummary: Equatable {
    var count: Int
    /// Reviewer logins in order of first review, without repeats.
    var reviewers: [String]
    var last: Date
}

extension [Event] {
    var reviewSummary: ReviewSummary? {
        let reviews = filter { $0.kind == .reviewSubmitted }
        guard let last = reviews.map(\.occurredAt).max() else { return nil }
        var seen = Set<String>()
        let reviewers = reviews.compactMap(\.actor?.login).filter { seen.insert($0).inserted }
        return ReviewSummary(count: reviews.count, reviewers: reviewers, last: last)
    }
}
