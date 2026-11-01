import Foundation

/// Shareable subset of `Config`: no repository ids, launcher bindings, or script executables.
public struct ExportedConfig: Codable, Hashable, Sendable {
    public struct RepositoryEntry: Codable, Hashable, Sendable {
        public var host: String
        public var fullName: String
        public var mutedEventKinds: Set<EventKind>
    }

    public enum Scope: Codable, Hashable, Sendable {
        case all
        /// `host/fullName` keys.
        case only([String])

        private enum CodingKeys: String, CodingKey { case type, repositories }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = try c.decode(String.self, forKey: .type) == "only" ? .only(try c.decode([String].self, forKey: .repositories)) : .all
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .all: try c.encode("all", forKey: .type)
            case .only(let keys): try c.encode("only", forKey: .type); try c.encode(keys, forKey: .repositories)
            }
        }
    }

    public struct RuleEntry: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var enabled: Bool
        public var priority: Int
        public var eventKind: EventKind
        public var repoScope: Scope
        public var conditions: [Condition]
        public var settleSeconds: Int
        public var launcherId: LauncherID
        public var workspacePolicy: WorkspacePolicy
        public var promptTemplateId: String
        public var executionMode: ExecutionMode
    }

    public var schemaVersion: Int
    public var repositories: [RepositoryEntry]
    public var launchers: [LauncherConfig]
    public var promptTemplates: [PromptTemplate]
    public var rules: [RuleEntry]
}

public enum ImportConflictPolicy: Sendable {
    case overwrite
    /// Imports clashing rules and templates under fresh ids.
    case rename
}

public struct ImportResult: Sendable {
    public var config: Config
    /// Rule and template ids that already existed; resolved with the chosen policy.
    public var conflicts: [String]
    /// Script launchers imported without an executable; the user must pick one.
    public var launchersNeedingExecutable: [LauncherID]
}

public enum ConfigExport {
    static let scriptLauncherType = "script"

    static func key(host: String, fullName: String) -> String { "\(host)/\(fullName)" }

    public static func export(_ config: Config) -> ExportedConfig {
        ExportedConfig(
            schemaVersion: config.schemaVersion,
            repositories: config.repositories.map { .init(host: $0.host, fullName: $0.fullName, mutedEventKinds: $0.mutedEventKinds) },
            launchers: config.launchers.map(stripExecutable),
            promptTemplates: config.promptTemplates,
            rules: config.rules.map { rule in
                let scope: ExportedConfig.Scope = switch rule.repoScope {
                case .all: .all
                case .only(let ids): .only(ids.compactMap { config.repository(id: $0).map { key(host: $0.host, fullName: $0.fullName) } })
                }
                return .init(id: rule.id, name: rule.name, enabled: rule.enabled, priority: rule.priority, eventKind: rule.eventKind,
                             repoScope: scope, conditions: rule.conditions, settleSeconds: rule.settleSeconds, launcherId: rule.launcherId,
                             workspacePolicy: rule.workspacePolicy, promptTemplateId: rule.promptTemplateId, executionMode: rule.executionMode)
            })
    }

    public static func importing(_ exported: ExportedConfig, into base: Config, conflictPolicy: ImportConflictPolicy) -> ImportResult {
        var config = base
        var conflicts: [String] = []
        var needingExecutable: [LauncherID] = []

        for entry in exported.repositories {
            if let i = config.repositories.firstIndex(where: { $0.host == entry.host && $0.fullName == entry.fullName }) {
                config.repositories[i].mutedEventKinds = entry.mutedEventKinds
            } else {
                config.repositories.append(Repository(host: entry.host, fullName: entry.fullName, mutedEventKinds: entry.mutedEventKinds))
            }
        }

        for launcher in exported.launchers where config.launcher(id: launcher.id) == nil {
            let stripped = stripExecutable(launcher)
            config.launchers.append(stripped)
            if stripped.type == scriptLauncherType { needingExecutable.append(stripped.id) }
        }

        var templateIds: [String: String] = [:]
        for var template in exported.promptTemplates {
            if let i = config.promptTemplates.firstIndex(where: { $0.id == template.id }) {
                conflicts.append(template.id)
                if conflictPolicy == .overwrite {
                    config.promptTemplates[i] = template
                    continue
                }
                templateIds[template.id] = UUID().uuidString
                template.id = templateIds[template.id]!
            }
            config.promptTemplates.append(template)
        }

        let repoIds = Dictionary(config.repositories.map { (key(host: $0.host, fullName: $0.fullName), $0.id) }, uniquingKeysWith: { a, _ in a })
        for entry in exported.rules {
            let scope: RepoScope = switch entry.repoScope {
            case .all: .all
            case .only(let keys): .only(keys.compactMap { repoIds[$0] })
            }
            var rule = Rule(id: entry.id, name: entry.name, enabled: entry.enabled, priority: entry.priority, eventKind: entry.eventKind,
                            repoScope: scope, conditions: entry.conditions, settleSeconds: entry.settleSeconds, launcherId: entry.launcherId,
                            workspacePolicy: entry.workspacePolicy, promptTemplateId: templateIds[entry.promptTemplateId] ?? entry.promptTemplateId,
                            executionMode: entry.executionMode)
            if let i = config.rules.firstIndex(where: { $0.id == rule.id }) {
                conflicts.append(rule.id)
                if conflictPolicy == .overwrite {
                    config.rules[i] = rule
                    continue
                }
                rule.id = UUID().uuidString
            }
            config.rules.append(rule)
        }

        return ImportResult(config: config, conflicts: conflicts, launchersNeedingExecutable: needingExecutable)
    }

    private static func stripExecutable(_ launcher: LauncherConfig) -> LauncherConfig {
        guard launcher.type == scriptLauncherType, case .object(var settings) = launcher.settings else { return launcher }
        settings["executable"] = nil
        return LauncherConfig(id: launcher.id, type: launcher.type, settings: .object(settings))
    }
}
