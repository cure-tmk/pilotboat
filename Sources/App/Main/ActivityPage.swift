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
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var days: [(day: Date, runs: [Run])] {
        let calendar = Calendar.current
        return Dictionary(grouping: runs) { calendar.startOfDay(for: $0.updatedAt) }
            .map { (day: $0.key, runs: $0.value) }
            .sorted { $0.day > $1.day }
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
                        ForEach(days, id: \.day) { group in
                            Section(dayTitle(group.day)) {
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

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today", bundle: .resources) }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday", bundle: .resources) }
        return day.formatted(date: .long, time: .omitted)
    }
}
