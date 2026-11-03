import AppKit
import Core
import Persistence
import SwiftUI

struct HealthPage: View {
    @Environment(AppModel.self) private var model
    @State private var showsSignIn = false

    private static let tools = ["git", "orca", "claude"]

    private var launcherGroups: [(name: String, items: [DiagnosticItem])] {
        let items = model.diagnostics.filter { !Self.tools.contains($0.title) && $0.title != "PATH" }
        var groups: [(name: String, items: [DiagnosticItem])] = []
        for item in items {
            let name = item.title.split(separator: ":", maxSplits: 1).first.map(String.init) ?? item.title
            if let index = groups.firstIndex(where: { $0.name == name }) {
                groups[index].items.append(item)
            } else {
                groups.append((name, [item]))
            }
        }
        return groups
    }

    var body: some View {
        Form {
            statusSection
            githubSection
            toolsSection
            ForEach(launcherGroups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.items, id: \.self) { item in
                        Label {
                            VStack(alignment: .leading) {
                                Text(item.title.split(separator: ":", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? item.title)
                                if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                        } icon: {
                            Image(systemName: item.level == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(item.level == .ok ? .green : item.level == .warning ? .orange : .red)
                        }
                    }
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
                LabeledContent { Text("\(remaining.formatted()) of 5,000 requests this hour", bundle: .resources) } label: { Text("GitHub API", bundle: .resources) }
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
                if let login = model.githubLogin { Text(login) } else { Text("Not signed in", bundle: .resources).foregroundStyle(.red) }
            } label: { Text("Account", bundle: .resources) }
            LabeledContent { Text("Stored in Keychain", bundle: .resources) } label: { Text("Token", bundle: .resources) }
            Captioned("Scopes", caption: "Needs read access to repositories and pull requests. Classic token: repo scope. Fine-grained token: Pull requests (Read) and Metadata (Read).")
            if model.githubLogin != nil {
                Button(role: .destructive) { Task { await model.signOut() } } label: { Text("Sign out", bundle: .resources) }
            } else {
                Button { showsSignIn = true } label: { Text("Sign in…", bundle: .resources) }
            }
        } header: {
            Text("GitHub", bundle: .resources)
        }
    }

    private var toolsSection: some View {
        Section {
            ForEach(Self.tools, id: \.self) { tool in
                let item = model.diagnostics.first { $0.title == tool }
                let found = item?.level == .ok || item?.detail?.contains(" — ") == true
                LabeledContent {
                    VStack(alignment: .trailing) {
                        if let item, found {
                            Text(item.detail ?? "").textSelection(.enabled)
                        } else {
                            Text("Not found on PATH", bundle: .resources).foregroundStyle(.red)
                            Text("Install with Homebrew", bundle: .resources).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } label: { Text(verbatim: tool) }
            }
        } header: {
            Text("Tools", bundle: .resources)
        }
    }

    private var troubleshootingSection: some View {
        Section {
            Button {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "pilotboat-logs.txt"
                if panel.runModal() == .OK, let url = panel.url { Task { await model.exportLogs(to: url) } }
            } label: { Text("Export logs…", bundle: .resources) }
            Button { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configURL]) } label: { Text("Reveal configuration folder", bundle: .resources) }
            DisclosureGroup {
                Text(model.resolvedSearchPath.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } label: { Text("Resolved PATH", bundle: .resources) }
        } header: {
            Text("Troubleshooting", bundle: .resources)
        }
    }
}
