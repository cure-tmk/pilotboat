import Core
import SwiftUI

struct ActivityPage: View {
    @Environment(AppModel.self) private var model
    @State private var filter = Filter.all

    enum Filter: Hashable { case all, waiting, failed }

    private var runs: [Run] {
        model.recentRuns
            .filter { run in
                switch filter {
                case .all: true
                case .waiting: run.state == .pendingApproval
                case .failed: run.state == .failed
                }
            }
    }

    var body: some View {
        @Bindable var router = model.router
        HSplitView {
            VStack(spacing: 0) {
                Picker(selection: $filter) {
                    Text("All", bundle: .resources).tag(Filter.all)
                    Text("Waiting", bundle: .resources).tag(Filter.waiting)
                    Text("Failed", bundle: .resources).tag(Filter.failed)
                } label: { Text("Filter", bundle: .resources) }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                if runs.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $router.runId) {
                        ForEach(runs.groupedByDay(), id: \.day) { group in
                            Section(group.title) {
                                ForEach(group.runs) { run in
                                    RunRow(run: run, showsDetails: true).tag(run.id)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 340, maxWidth: 420, maxHeight: .infinity, alignment: .top)
            Group {
                if let run = model.recentRuns.first(where: { $0.id == router.runId }) {
                    RunDetail(run: run)
                } else {
                    ContentUnavailableView { Label { Text("Select a run", bundle: .resources) } icon: { Image(systemName: "list.bullet.rectangle") } }
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var emptyState: some View {
        switch filter {
        case .all: empty(Text("No runs yet", bundle: .resources), "tray")
        case .waiting: empty(Text("Nothing is waiting for you", bundle: .resources), "checkmark.circle")
        case .failed: empty(Text("No failures", bundle: .resources), "checkmark.circle")
        }
    }

    private func empty(_ title: Text, _ symbol: String) -> some View {
        ContentUnavailableView { Label { title } icon: { Image(systemName: symbol) } }
    }
}

struct RunDay {
    let day: Date
    let title: String
    let runs: [Run]
}

extension [Run] {
    /// Newest day first, runs newest first; days are titled Today, Yesterday or the date.
    func groupedByDay(calendar: Calendar = .current, now: Date = Date()) -> [RunDay] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        return Dictionary(grouping: self) { calendar.startOfDay(for: $0.updatedAt) }
            .sorted { $0.key > $1.key }
            .map { day, runs in
                let title = day == today ? String(localized: "Today", bundle: .resources)
                    : day == yesterday ? String(localized: "Yesterday", bundle: .resources)
                    : day.formatted(date: .long, time: .omitted)
                return RunDay(day: day, title: title, runs: runs.sorted { $0.updatedAt > $1.updatedAt })
            }
    }
}
