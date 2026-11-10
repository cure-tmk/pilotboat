import Core
import Foundation

public enum ConfigStoreError: Error, Equatable {
    case corrupt(path: String, backupAvailable: Bool)
    case noBackup
    /// Written by a newer Pilotboat; loading it would drop what this version does not know.
    case newerSchema(found: Int)
}

enum ConfigMigrations {
    typealias Step = @Sendable (inout [String: Any]) throws -> Void

    /// Index i upgrades schemaVersion i+1 to i+2. Add one function per bump.
    static let steps: [Step] = []

    static func migrate(json: inout [String: Any], steps: [Step] = steps, target: Int = Config.currentSchemaVersion) throws {
        var version = json["schemaVersion"] as? Int ?? 1
        guard version <= target else { throw ConfigStoreError.newerSchema(found: version) }
        while version < target, version - 1 < steps.count {
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
        do { return try Self.decode(Data(contentsOf: url)) } catch let error as ConfigStoreError { throw error } catch {
            throw ConfigStoreError.corrupt(path: url.path, backupAvailable: (try? Self.decode(Data(contentsOf: backupURL))) != nil)
        }
    }

    public func save(_ config: Config) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // A corrupt current file must not overwrite a good backup.
        if (try? Self.decode(Data(contentsOf: url))) != nil {
            try install(copyOf: url, at: backupURL)
        }
        let tmp = directory.appendingPathComponent("config.json.tmp")
        try encoder.encode(config).write(to: tmp)
        try install(tmp, at: url)
    }

    @discardableResult
    public func restoreFromBackup() throws -> Config {
        guard let config = try? Self.decode(Data(contentsOf: backupURL)) else { throw ConfigStoreError.noBackup }
        try install(copyOf: backupURL, at: url)
        return config
    }

    private func install(copyOf source: URL, at destination: URL) throws {
        let tmp = destination.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: source, to: tmp)
        try install(tmp, at: destination)
    }

    /// Atomically puts `tmp` at `destination`, so a crash leaves either the old or the new file.
    private func install(_ tmp: URL, at destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: destination) }
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
