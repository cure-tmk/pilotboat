import Core
import SwiftUI

struct AutomationsStep: View {
    @Environment(AppModel.self) private var model
    @Binding var includeExisting: Bool
    /// Owned by the window so going Back and Continue again does not re-enable presets the user switched off.
    @Binding var presetsInitialized: Bool
    @State private var checking = true

    private nonisolated static let presetIds = [Presets.reviewRequestedId, Presets.reviewReceivedId]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Automations")
            ForEach(Self.presetIds, id: \.self) { id in
                if let rule = model.config.rule(id: id) { card(rule) }
            }
            waiting
            Toggle(String(localized: "Handle them too", bundle: .resources), isOn: $includeExisting)
            Text("Off by default so that old requests do not all start at once", bundle: .resources)
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            if !presetsInitialized {
                presetsInitialized = true
                model.edit { config in
                    for i in config.rules.indices where Self.presetIds.contains(config.rules[i].id) { config.rules[i].enabled = true }
                }
            }
            await model.pollOnce()
            checking = false
        }
    }

    @ViewBuilder private func card(_ rule: Rule) -> some View {
        let isPreset = rule.id.hasPrefix("preset.")
        let toggle = Toggle(isOn: Binding(get: { rule.enabled }, set: { set(rule.id, $0) })) {
            isPreset ? Text(LocalizedStringKey(rule.name), bundle: .resources) : Text(verbatim: rule.name)
        }
        .toggleStyle(.switch).controlSize(.small).labelsHidden()
        if isPreset {
            SectionCard(LocalizedStringKey(rule.name), trailing: { toggle }) { details(rule) }
        } else {
            SectionCard(verbatim: rule.name, trailing: { toggle }) { details(rule) }
        }
    }

    @ViewBuilder private func details(_ rule: Rule) -> some View {
        Text(rule.eventKind.triggerDescription).font(.caption).foregroundStyle(.secondary)
        if let template = model.config.promptTemplate(id: rule.promptTemplateId) {
            DisclosureGroup(String(localized: "Instructions", bundle: .resources)) {
                Text(template.body).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var waiting: some View {
        let count = model.status.openReviewRequests.count
        if checking {
            HStack(spacing: 6) {
                Text("Review requests already waiting:", bundle: .resources)
                ProgressView().controlSize(.small)
                Text("Checking…", bundle: .resources).foregroundStyle(.secondary)
            }
        } else if count == 0 {
            Text("Review requests already waiting: none", bundle: .resources)
        } else {
            Text("Review requests already waiting: \(count)", bundle: .resources)
        }
    }

    private func set(_ id: String, _ on: Bool) {
        model.edit { config in
            if let i = config.rules.firstIndex(where: { $0.id == id }) { config.rules[i].enabled = on }
        }
    }
}
