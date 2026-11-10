import AppKit
import Core
import Foundation
import OSLog
import Persistence
import SourceGitHub

extension AppModel {
    func openMain(section: MainSection? = nil, runId: UUID? = nil, automationId: String? = nil, repositoryId: UUID? = nil) {
        shell?.closePopover()
        router.show(section: section, runId: runId, automationId: automationId, repositoryId: repositoryId)
        shell?.showMain()
    }

    func openSettings() {
        shell?.closePopover()
        NSApp.activate()
        // `showSettingsWindow:` sent directly is ignored on recent macOS; the app menu's Settings item still works.
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) else { return }
        menu.performActionForItem(at: index)
    }

    func exportConfig(to url: URL) async {
        await perform {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ConfigExport.export(config)).write(to: url, options: .atomic)
        }
    }

    /// Applies the import right away; the result lists conflicts resolved with `policy` and launchers needing an executable.
    /// `nil` when saving the merged settings failed, which `lastErrorMessage` then explains.
    func importConfig(from url: URL, policy: ImportConflictPolicy) async throws -> ImportResult? {
        let current = config
        let result = try await described {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return ConfigExport.importing(try decoder.decode(ExportedConfig.self, from: Data(contentsOf: url)), into: current, conflictPolicy: policy)
        }
        let imported = result.config
        return await updateConfig { $0 = imported } ? result : nil
    }

    func exportLogs(to url: URL) async {
        await perform { try await Task.detached { try Self.writeLogs(to: url) }.value }
    }

    private nonisolated static func writeLogs(to url: URL) throws {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: Date().addingTimeInterval(-86_400)),
                                           matching: NSPredicate(format: "subsystem == %@", AppPaths.bundleID))
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
            "\($0.date.formatted(.iso8601)) [\($0.category)] \(TokenMasker.mask($0.composedMessage))"
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
