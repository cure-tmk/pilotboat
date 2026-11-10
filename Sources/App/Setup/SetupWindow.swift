import Core
import LauncherOrca
import LauncherScript
import SwiftUI

struct SetupWindow: View {
    @Environment(AppModel.self) private var model
    @State private var step = 1
    @State private var busy = false
    @State private var includeExisting = false
    @State private var presetsInitialized = false
    @State private var launcher = LauncherChoice()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                switch step {
                case 1: GitHubStep()
                case 2: LauncherStep(launcher: launcher)
                case 3: RepositoriesStep(launcher: launcher)
                default: AutomationsStep(includeExisting: $includeExisting, presetsInitialized: $presetsInitialized)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ErrorBanner(message: Bindable(model).lastErrorMessage)
            footer
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Back", bundle: .resources)) { step -= 1 }.disabled(step == 1 || busy)
            Spacer()
            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { Circle().fill($0 == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7) }
            }
            .accessibilityElement().accessibilityLabel(Text("Step \(step) of 4", bundle: .resources))
            Spacer()
            if step < 4 {
                Button(String(localized: "Continue", bundle: .resources)) { advance() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canContinue || busy)
            } else {
                Button(String(localized: "Finish", bundle: .resources)) {
                    Task { busy = true; await model.completeOnboarding(includeExistingReviewRequests: includeExisting); busy = false }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
    }

    private var canContinue: Bool {
        switch step {
        case 1: model.account.login != nil
        case 2: launcher.isValid && ["git", "claude"].allSatisfy { model.health.tool($0)?.isOK == true }
        default: !model.config.repositories.isEmpty
        }
    }

    private func advance() {
        Task {
            busy = true
            if step == 2 { await launcher.apply(to: model) }
            step += 1
            busy = false
        }
    }
}

@MainActor @Observable
final class LauncherChoice {
    enum Kind { case orca, script }
    var kind: Kind = .script
    var agent = "claude"
    var scriptPath = ""

    var isValid: Bool {
        switch kind {
        case .orca: !agent.trimmingCharacters(in: .whitespaces).isEmpty
        case .script: !scriptPath.isEmpty
        }
    }

    func apply(to model: AppModel) async {
        let agent = agent.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .orca:
            let id = model.config.launchers(ofType: OrcaLauncher.typeID).first?.id ?? Bootstrap.defaultOrcaLauncherId
            await model.updateConfig { config in
                var settings = config.launcher(id: id).flatMap { try? OrcaSettings(json: $0.settings) } ?? OrcaSettings(agent: agent)
                settings.agent = agent
                let json = (try? settings.json()) ?? .object(["agent": .string(agent)])
                if let i = config.launchers.firstIndex(where: { $0.id == id }) {
                    config.launchers[i].settings = json
                } else {
                    config.launchers.append(LauncherConfig(id: id, type: OrcaLauncher.typeID, settings: json))
                }
                config.useLauncherForPresets(id)
            }
        case .script:
            let id = ScriptLauncher.typeID
            let settings = ScriptSettings(executable: scriptPath).json()
            await model.updateConfig { config in
                config.launchers.removeAll { $0.id == id }
                config.launchers.append(LauncherConfig(id: id, type: ScriptLauncher.typeID, settings: settings))
                config.useLauncherForPresets(id)
            }
        }
    }
}

struct StepHeader: View {
    let title: LocalizedStringKey
    var body: some View { Text(title, bundle: .resources).font(.title2.bold()) }
}
