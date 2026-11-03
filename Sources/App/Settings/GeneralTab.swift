import Core
import SwiftUI

struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    @State private var newActor = ""

    private var general: GeneralSettings { model.config.general }

    private func binding<T: Sendable>(_ keyPath: WritableKeyPath<GeneralSettings, T> & Sendable) -> Binding<T> {
        Binding(get: { model.config.general[keyPath: keyPath] },
                set: { value in Task { await model.updateConfig { $0.general[keyPath: keyPath] = value } } })
    }

    private var intervals: [Int] { Array(Set([60, 120, 300, 600, 900, general.pollIntervalSeconds])).sorted() }

    var body: some View {
        Form {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { on in Task { await model.setLaunchAtLogin(on) } })) {
                Text("Start at login", bundle: .resources)
            }
            Toggle(isOn: binding(\.notificationsEnabled)) { Text("Notifications", bundle: .resources) }
            Picker(selection: binding(\.pollIntervalSeconds)) {
                ForEach(intervals, id: \.self) { seconds in
                    Text(seconds % 60 == 0 ? String(localized: "\(seconds / 60) min", bundle: .resources) : String(localized: "\(seconds) sec", bundle: .resources)).tag(seconds)
                }
            } label: { Text("Check GitHub every", bundle: .resources) }

            Section {
                Stepper(value: binding(\.maxConcurrentLaunches), in: 1...10) {
                    Text("Run at most \(general.maxConcurrentLaunches) agents at the same time", bundle: .resources)
                }
                Stepper(value: binding(\.dailyLaunchLimit), in: 1...200) {
                    Text("Start at most \(general.dailyLaunchLimit) agents per day", bundle: .resources)
                }
            } header: { Text("Limits", bundle: .resources) }

            Section {
                Toggle(isOn: binding(\.includeTeamReviewRequests)) { Text("Include requests sent to my teams", bundle: .resources) }
                ForEach(general.excludedActors, id: \.self) { login in
                    LabeledContent(login) {
                        Button { Task { await model.updateConfig { $0.general.excludedActors.removeAll { $0 == login } } } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove", bundle: .resources))
                    }
                }
                TextField(String(localized: "Add a login to ignore", bundle: .resources), text: $newActor)
                    .onSubmit {
                        let login = newActor.trimmingCharacters(in: .whitespaces)
                        newActor = ""
                        guard !login.isEmpty, !general.excludedActors.contains(login) else { return }
                        Task { await model.updateConfig { $0.general.excludedActors.append(login) } }
                    }
            } header: { Text("Review requests", bundle: .resources) }
            footer: { Text("Ignore reviews from", bundle: .resources) }
        }
        .formStyle(.grouped)
    }
}
