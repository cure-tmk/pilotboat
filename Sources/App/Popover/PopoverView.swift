import AppKit
import Core
import SwiftUI

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingTurnOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if confirmingTurnOn { TurnOnConfirmation { confirmingTurnOn = false } } else { header }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.pendingRuns.isEmpty { waiting }
                    recent
                }
                .padding(12)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .top) {
            StatusLine(status: model.status)
            Spacer()
            if model.status.monitoring == .on {
                Menu {
                    Button { pause(.seconds(1800)) } label: { Text("30 minutes", bundle: .resources) }
                    Button { pause(.seconds(3600)) } label: { Text("1 hour", bundle: .resources) }
                    Button { Task { await model.pauseMonitoringUntilTomorrow() } } label: { Text("Until tomorrow", bundle: .resources) }
                    Divider()
                    Button { Task { await model.setMonitoring(false) } } label: { Text("Turn off", bundle: .resources) }
                } label: {
                    Text("Pause", bundle: .resources)
                }
                .fixedSize()
            } else {
                Button { confirmingTurnOn = true } label: { Text("Turn on", bundle: .resources) }
            }
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(Text("Waiting for you (\(model.pendingRuns.count))", bundle: .resources))
            ForEach(model.pendingRuns) { run in
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        PullRequestTitle(run: run)
                        Text("\(model.config.rule(id: run.ruleId)?.name ?? run.ruleId) · \(RelativeDate(date: run.updatedAt).body)", bundle: .resources)
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button { Task { await model.skip(runId: run.id) } } label: { Text("Skip", bundle: .resources) }
                            Button { Task { await model.approve(runId: run.id) } } label: { Text("Run", bundle: .resources) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(Text("Recent", bundle: .resources))
            if model.recentRuns.isEmpty {
                Text("Nothing has happened yet", bundle: .resources)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            ForEach(model.recentRuns.prefix(5)) { run in
                Button { model.openMain(section: .activity, runId: run.id) } label: {
                    RunRow(run: run).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { model.openMain() } label: { Text("Open Pilotboat", bundle: .resources) }
            Button { Task { await model.triggerTick() } } label: { Text("Check now", bundle: .resources) }
            Spacer()
            Button { model.openSettings() } label: { Image(systemName: "gearshape") }
                .help(Text("Settings", bundle: .resources))
                .accessibilityLabel(Text("Settings", bundle: .resources))
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help(Text("Quit Pilotboat", bundle: .resources))
                .accessibilityLabel(Text("Quit Pilotboat", bundle: .resources))
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
    }

    private func sectionTitle(_ text: Text) -> some View {
        text.font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func pause(_ duration: Duration) { Task { await model.pauseMonitoring(for: duration) } }
}

// Inline, not a sheet: a sheet on a MenuBarExtra window detaches from the panel or closes it.
private struct TurnOnConfirmation: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var includeExisting = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Turn on monitoring?", bundle: .resources).font(.headline)
                Toggle(isOn: $includeExisting) {
                    Captioned("Also handle review requests that are already waiting",
                              caption: "Otherwise only requests that arrive from now on are handled, so old requests don't start agents all at once")
                }
                .toggleStyle(.checkbox)
                HStack {
                    Spacer()
                    Button { done() } label: { Text("Cancel", bundle: .resources) }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        let include = includeExisting
                        done()
                        Task { await model.setMonitoring(true, includeExistingReviewRequests: include) }
                    } label: { Text("Turn on", bundle: .resources) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}
