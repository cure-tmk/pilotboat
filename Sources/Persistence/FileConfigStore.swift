import Core
import Foundation

public enum ConfigStoreError: Error, Equatable {
    case corrupt(path: String, backupAvailable: Bool)
    case noBackup
}

enum ConfigMigrations {
    /// Index i upgrades schemaVersion i+1 to i+2. Add one function per bump.
    static let steps: [@Sendable (inout [String: Any]) throws -> Void] = []

    static func migrate(json: inout [String: Any]) throws {
        var version = json["schemaVersion"] as? Int ?? 1
        while version < Config.currentSchemaVersion, version - 1 < steps.count {
            try steps[version - 1](&json)
            version += 1
            json["schemaVersion"] = version
        }
    }
}

public struct FileConfigStore: ConfigStore {
    private let directory: URL
    private var url: URL { directory.appendingPathComponent("config.json") }
    private var backupURL: URL { directory.appendingPathComponent("config.json.bak") }

    public init(directory: URL = AppPaths.supportDirectory) { self.directory = directory }

    public func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        do { return try Self.decode(Data(contentsOf: url)) } catch {
            throw ConfigStoreError.corrupt(path: url.path, backupAvailable: (try? Self.decode(Data(contentsOf: backupURL))) != nil)
        }
    }

    public func save(_ config: Config) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = directory.appendingPathComponent("config.json.tmp")
        try encoder.encode(config).write(to: tmp)
        if fm.fileExists(atPath: url.path) {
            // A corrupt current file must not overwrite a good backup.
            if (try? Self.decode(Data(contentsOf: url))) != nil {
                try? fm.removeItem(at: backupURL)
                try fm.copyItem(at: url, to: backupURL)
            }
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    @discardableResult
    public func restoreFromBackup() throws -> Config {
        guard let config = try? Self.decode(Data(contentsOf: backupURL)) else { throw ConfigStoreError.noBackup }
        let fm = FileManager.default
        let tmp = directory.appendingPathComponent("config.json.tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: backupURL, to: tmp)
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        return config
    }

    private static func decode(_ data: Data) throws -> Config {
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an object"))
        }
        try ConfigMigrations.migrate(json: &json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Config.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
