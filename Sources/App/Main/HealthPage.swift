import AppKit
import Core
import Persistence
import SwiftUI

struct HealthPage: View {
    @Environment(AppModel.self) private var model
    @State private var showsSignIn = false

    var body: some View {
        Form {
            statusSection
            githubSection
            toolsSection
            ForEach(model.health.groups, id: \.owner) { group in
                Section(group.owner) {
                    ForEach(group.items, id: \.self) { DiagnosticRow(item: $0) }
                }
            }
            troubleshootingSection
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshDiagnostics() } } label: { Label { Text("Check again", bundle: .resources) } icon: { Image(systemName: "arrow.clockwise") } }
            }
        }
        .task { await model.refreshDiagnostics() }
        .sheet(isPresented: $showsSignIn) { SignInSheet() }
    }

    private var statusSection: some View {
        let status = model.status
        return Section {
            LabeledContent {
                switch status.monitoring {
                case .on: Text("On", bundle: .resources)
                case .off: Text("Off", bundle: .resources)
                case .offUntil(let date): Text("Paused until \(date.formatted(date: .omitted, time: .shortened))", bundle: .resources)
                }
            } label: { Text("Monitoring", bundle: .resources) }
            LabeledContent {
                if let date = status.lastTickAt { RelativeDate(date: date).body } else { Text("Not checked yet", bundle: .resources) }
            } label: { Text("Last check", bundle: .resources) }
            if let next = model.nextCheckAt {
                LabeledContent { Text(next, style: .relative) } label: { Text("Next check", bundle: .resources) }
            }
            if let error = status.lastError {
                LabeledContent { Text(error).foregroundStyle(.red).textSelection(.enabled) } label: { Text("Last error", bundle: .resources) }
            }
            if let remaining = status.rateLimitRemaining {
                LabeledContent { Text("\(remaining.formatted()) requests remaining this hour", bundle: .resources) } label: { Text("GitHub API", bundle: .resources) }
            }
            if status.consecutiveFailures > 0 {
                LabeledContent { Text(status.consecutiveFailures.formatted()) } label: { Text("Consecutive failures", bundle: .resources) }
            }
        } header: {
            Text("Status", bundle: .resources)
        }
    }

    private var githubSection: some View {
        Section {
            LabeledContent {
                if let login = model.account.login { Text(login) } else { Text("Not signed in", bundle: .resources).foregroundStyle(.red) }
            } label: { Text("Account", bundle: .resources) }
            LabeledContent { Text("Stored in Keychain", bundle: .resources) } label: { Text("Token", bundle: .resources) }
            Captioned("Scopes", caption: "Needs read access to repositories and pull requests. Classic token: repo scope. Fine-grained token: Pull requests (Read) and Metadata (Read).")
            if model.account.login != nil {
                Button(role: .destructive) { Task { await model.account.signOut() } } label: { Text("Sign out", bundle: .resources) }
            } else {
                Button { showsSignIn = true } label: { Text("Sign in…", bundle: .resources) }
            }
        } header: {
            Text("GitHub", bundle: .resources)
        }
    }

    private var toolsSection: some View {
        Section {
            ForEach(model.health.tools, id: \.name) { DiagnosticRow(item: $0.item) }
        } header: {
            Text("Tools", bundle: .resources)
        }
    }

    private var troubleshootingSection: some View {
        Section {
            Button {
                if let url = Panel.save(name: "pilotboat-logs.txt") { Task { await model.exportLogs(to: url) } }
            } label: { Text("Export logs…", bundle: .resources) }
            Button { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configURL]) } label: { Text("Reveal configuration folder", bundle: .resources) }
            DisclosureGroup {
                Text(model.health.searchPath.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } label: { Text("Resolved PATH", bundle: .resources) }
        } header: {
            Text("Troubleshooting", bundle: .resources)
        }
    }
}
