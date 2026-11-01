import Foundation

public struct GeneralSettings: Codable, Hashable, Sendable {
    public var monitoring: Bool = true
    public var monitoringOffUntil: Date? = nil
    public var pollIntervalSeconds: Int = 120
    public var maxConcurrentLaunches: Int = 3
    public var dailyLaunchLimit: Int = 20
    public var includeTeamReviewRequests: Bool = false
    public var excludedActors: [String] = ["dependabot[bot]"]
    public var notificationsEnabled: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        monitoring = try c.decodeIfPresent(Bool.self, forKey: .monitoring) ?? d.monitoring
        monitoringOffUntil = try c.decodeIfPresent(Date.self, forKey: .monitoringOffUntil)
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? d.pollIntervalSeconds
        maxConcurrentLaunches = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentLaunches) ?? d.maxConcurrentLaunches
        dailyLaunchLimit = try c.decodeIfPresent(Int.self, forKey: .dailyLaunchLimit) ?? d.dailyLaunchLimit
        includeTeamReviewRequests = try c.decodeIfPresent(Bool.self, forKey: .includeTeamReviewRequests) ?? d.includeTeamReviewRequests
        excludedActors = try c.decodeIfPresent([String].self, forKey: .excludedActors) ?? d.excludedActors
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
    }
}

public struct PresetState: Codable, Hashable, Sendable {
    public var editedByUser: Bool
    public var version: Int
    public init(editedByUser: Bool = false, version: Int) { self.editedByUser = editedByUser; self.version = version }
}

public struct Config: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = Config.currentSchemaVersion
    public var general: GeneralSettings = GeneralSettings()
    public var repositories: [Repository] = []
    public var launchers: [LauncherConfig] = []
    public var promptTemplates: [PromptTemplate] = []
    public var rules: [Rule] = []
    public var presetState: [String: PresetState] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Config.currentSchemaVersion
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? GeneralSettings()
        repositories = try c.decodeIfPresent([Repository].self, forKey: .repositories) ?? []
        launchers = try c.decodeIfPresent([LauncherConfig].self, forKey: .launchers) ?? []
        promptTemplates = try c.decodeIfPresent([PromptTemplate].self, forKey: .promptTemplates) ?? []
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        presetState = try c.decodeIfPresent([String: PresetState].self, forKey: .presetState) ?? [:]
    }

    public func repository(id: UUID) -> Repository? { repositories.first { $0.id == id } }
    public func repository(host: String, fullName: String) -> Repository? {
        repositories.first { $0.host == host && $0.fullName == fullName }
    }
    public func rule(id: String) -> Rule? { rules.first { $0.id == id } }
    public func promptTemplate(id: String) -> PromptTemplate? { promptTemplates.first { $0.id == id } }
    public func launcher(id: LauncherID) -> LauncherConfig? { launchers.first { $0.id == id } }
}

public protocol ConfigStore: Sendable {
    /// Returns a default `Config` when no file exists yet.
    func load() throws -> Config
    func save(_ config: Config) throws
}
