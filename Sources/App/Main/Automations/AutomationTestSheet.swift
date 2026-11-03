import Core
import SwiftUI

struct AutomationTestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let rule: Rule

    @State private var urlText = ""
    @State private var report: DryRunReport?
    @State private var run: Run?
    @State private var error: String?
    @State private var busy = false
    @State private var confirmsStart = false

    private var url: URL? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" || url.scheme == "http", url.host() != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test “\(rule.name)”", bundle: .resources).font(.headline)
            HStack {
                TextField(text: $urlText, prompt: Text(verbatim: "https://github.com/owner/repo/pull/123")) {
                    Text("Pull request URL", bundle: .resources)
                }
                .onSubmit(preview)
                Button(action: preview) { Text("Preview", bundle: .resources) }
                    .disabled(url == nil || busy)
            }
            if busy { ProgressView().controlSize(.small) }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let report { result(report) } else { Spacer() }
            if let run {
                HStack {
                    RunStateBadge(run: run)
                    Spacer()
                    Button {
                        model.router.show(section: .activity, runId: run.id)
                        dismiss()
                    } label: { Text("Show in Activity", bundle: .resources) }
                }
            }
            HStack {
                Spacer()
                Button { confirmsStart = true } label: { Text("Start now", bundle: .resources) }
                    .disabled(url == nil || busy)
                Button { dismiss() } label: { Text("Done", bundle: .resources) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .alert(Text("Start an agent for this pull request?", bundle: .resources), isPresented: $confirmsStart) {
            Button(action: start) { Text("Start agent", bundle: .resources) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .resources) }
        } message: {
            Text("“\(rule.name)” runs now, even if it would not match this pull request", bundle: .resources)
        }
    }

    private func result(_ report: DryRunReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let mismatch = report.mismatch {
                    Label { Text(mismatch.verdict) } icon: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                } else {
                    Label { Text("Would run", bundle: .resources) } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if let winner = report.winningRule, winner.id != rule.id {
                    if case .outranked = report.mismatch {} else {
                        Text("\(winner.name) would run instead", bundle: .resources).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Instructions", bundle: .resources).font(.headline)
                Text(report.renderedPrompt).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("Commands", bundle: .resources).font(.headline)
                Text(report.launcherDescription).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func preview() {
        guard let url, !busy else { return }
        perform { report = try await model.dryRun(ruleId: rule.id, prURL: url) }
    }

    private func start() {
        guard let url else { return }
        perform { run = try await model.trialRun(ruleId: rule.id, prURL: url) }
    }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await body() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private extension RuleMismatch {
    var verdict: String {
        switch self {
        case .repoNotRegistered: String(localized: "Would not run: the repository has not been added to Pilotboat", bundle: .resources)
        case .repoOff: String(localized: "Would not run: the repository is not monitored", bundle: .resources)
        case .muted: String(localized: "Would not run: this trigger is ignored in this repository", bundle: .resources)
        case .ruleDisabled: String(localized: "Would not run: this automation is turned off", bundle: .resources)
        case .eventKind: String(localized: "Would not run: the trigger does not match", bundle: .resources)
        case .repoScope: String(localized: "Would not run: this automation does not cover the repository", bundle: .resources)
        case .condition(.actorKind(.bot)): String(localized: "Would not run: the review is not from a bot", bundle: .resources)
        case .condition(.actorKind): String(localized: "Would not run: the review is from a bot", bundle: .resources)
        case .condition(.includeDraft): String(localized: "Would not run: this pull request is a draft", bundle: .resources)
        case .condition(.labelsInclude): String(localized: "Would not run: the pull request has none of the required labels", bundle: .resources)
        case .condition(.labelsExclude): String(localized: "Would not run: the pull request has an excluded label", bundle: .resources)
        case .outranked(let winner): String(localized: "Would not run: \(winner.name) is higher in the list and matches", bundle: .resources)
        }
    }
}
